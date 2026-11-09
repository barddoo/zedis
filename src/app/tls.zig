//! Server-side TLS for client connections, backed by Mbed TLS.
//!
//! The zio runtime is cooperative: a "blocking" socket read only suspends the
//! calling coroutine, so Mbed TLS can use its ordinary blocking BIO callbacks
//! on top of `std.Io.net.Stream`. The SSL context is not thread-safe, but the
//! server runs a single executor and serializes writes per client with the
//! client's write mutex, so one context is only ever touched by one coroutine
//! at a time.

const std = @import("std");

const c = @import("mbedtls_c");

const Io = std.Io;
const Stream = Io.net.Stream;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tls);

pub const AuthClients = enum {
    /// Do not ask the client for a certificate.
    no,
    /// Ask, and verify any certificate the client sends.
    optional,
    /// Require a certificate signed by the configured CA.
    required,
};

pub const Options = struct {
    cert_file: []const u8,
    key_file: []const u8,
    ca_file: []const u8 = "",
    auth_clients: AuthClients = .required,
    /// Space-separated protocol list, as in Redis' `tls-protocols`.
    protocols: []const u8 = "",
};

pub const InitError = error{
    MissingCertFile,
    MissingKeyFile,
    MissingCaCertFile,
    CryptoInitFailed,
    CertParseFailed,
    KeyParseFailed,
    CaParseFailed,
    ConfigFailed,
    UnsupportedProtocol,
    OutOfMemory,
};

/// Process-wide TLS configuration shared by every accepted connection. The
/// Mbed TLS contexts stay at a fixed address for their whole lifetime because
/// `mbedtls_ssl_conf_own_cert` stores pointers into them.
pub const Server = struct {
    allocator: Allocator,
    config: c.mbedtls_ssl_config,
    cert: c.mbedtls_x509_crt,
    key: c.mbedtls_pk_context,
    ca: c.mbedtls_x509_crt,
    has_ca: bool,

    pub fn create(allocator: Allocator, options: Options) InitError!*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .config = undefined,
            .cert = undefined,
            .key = undefined,
            .ca = undefined,
            .has_ca = false,
        };
        try self.setup(options);
        return self;
    }

    fn setup(self: *Server, options: Options) InitError!void {
        if (options.cert_file.len == 0) return error.MissingCertFile;
        if (options.key_file.len == 0) return error.MissingKeyFile;
        if (options.auth_clients != .no and options.ca_file.len == 0) return error.MissingCaCertFile;

        if (c.psa_crypto_init() != 0) return error.CryptoInitFailed;

        c.mbedtls_ssl_config_init(&self.config);
        c.mbedtls_x509_crt_init(&self.cert);
        c.mbedtls_pk_init(&self.key);
        c.mbedtls_x509_crt_init(&self.ca);
        errdefer self.free();

        const cert_path = try self.allocator.dupeSentinel(u8, options.cert_file, 0);
        defer self.allocator.free(cert_path);
        if (c.mbedtls_x509_crt_parse_file(&self.cert, cert_path.ptr) != 0)
            return error.CertParseFailed;

        const key_path = try self.allocator.dupeSentinel(u8, options.key_file, 0);
        defer self.allocator.free(key_path);
        if (c.mbedtls_pk_parse_keyfile(&self.key, key_path.ptr, null) != 0)
            return error.KeyParseFailed;

        if (options.ca_file.len != 0) {
            const ca_path = try self.allocator.dupeSentinel(u8, options.ca_file, 0);
            defer self.allocator.free(ca_path);
            if (c.mbedtls_x509_crt_parse_file(&self.ca, ca_path.ptr) != 0)
                return error.CaParseFailed;
            self.has_ca = true;
        }

        if (c.mbedtls_ssl_config_defaults(
            &self.config,
            c.MBEDTLS_SSL_IS_SERVER,
            c.MBEDTLS_SSL_TRANSPORT_STREAM,
            c.MBEDTLS_SSL_PRESET_DEFAULT,
        ) != 0) return error.ConfigFailed;

        try self.applyProtocols(options.protocols);

        c.mbedtls_ssl_conf_authmode(&self.config, switch (options.auth_clients) {
            .no => c.MBEDTLS_SSL_VERIFY_NONE,
            .optional => c.MBEDTLS_SSL_VERIFY_OPTIONAL,
            .required => c.MBEDTLS_SSL_VERIFY_REQUIRED,
        });
        if (self.has_ca) c.mbedtls_ssl_conf_ca_chain(&self.config, &self.ca, null);
        if (c.mbedtls_ssl_conf_own_cert(&self.config, &self.cert, &self.key) != 0)
            return error.ConfigFailed;
    }

    fn applyProtocols(self: *Server, protocols: []const u8) error{UnsupportedProtocol}!void {
        const range = try parseProtocolRange(protocols);
        if (range.min) |version| c.mbedtls_ssl_conf_min_tls_version(&self.config, version);
        if (range.max) |version| c.mbedtls_ssl_conf_max_tls_version(&self.config, version);
    }

    fn free(self: *Server) void {
        c.mbedtls_ssl_config_free(&self.config);
        c.mbedtls_x509_crt_free(&self.cert);
        c.mbedtls_pk_free(&self.key);
        c.mbedtls_x509_crt_free(&self.ca);
    }

    pub fn destroy(self: *Server) void {
        self.free();
        self.allocator.destroy(self);
    }
};

pub const Error = error{
    HandshakeFailed,
    ReadFailed,
    WriteFailed,
    Canceled,
};

const ProtocolRange = struct {
    min: ?c.mbedtls_ssl_protocol_version = null,
    max: ?c.mbedtls_ssl_protocol_version = null,
};

fn parseProtocolRange(protocols: []const u8) error{UnsupportedProtocol}!ProtocolRange {
    var range: ProtocolRange = .{};
    var tokens = std.mem.tokenizeAny(u8, protocols, " \t,");
    while (tokens.next()) |token| {
        const version: c.mbedtls_ssl_protocol_version = if (std.mem.eql(u8, token, "TLSv1.2"))
            c.MBEDTLS_SSL_VERSION_TLS1_2
        else if (std.mem.eql(u8, token, "TLSv1.3"))
            c.MBEDTLS_SSL_VERSION_TLS1_3
        else
            return error.UnsupportedProtocol;

        range.min = if (range.min) |current| @min(current, version) else version;
        range.max = if (range.max) |current| @max(current, version) else version;
    }
    return range;
}

/// One TLS-wrapped client socket. Allocated on the heap so the SSL context has
/// a stable address for its lifetime.
pub const Connection = struct {
    stream: Stream,
    io: Io,
    server: *Server,
    ssl: c.mbedtls_ssl_context,
    initialized: bool = false,
    /// Set when a BIO callback saw zio cancellation, so `read` can surface it
    /// instead of the generic Mbed TLS recv failure.
    canceled: bool = false,

    pub fn accept(stream: Stream, io: Io, server: *Server) Error!*Connection {
        const allocator = server.allocator;
        const self = allocator.create(Connection) catch return error.HandshakeFailed;
        self.* = .{
            .stream = stream,
            .io = io,
            .server = server,
            .ssl = undefined,
        };

        c.mbedtls_ssl_init(&self.ssl);
        self.initialized = true;
        errdefer self.destroy();

        if (c.mbedtls_ssl_setup(&self.ssl, &server.config) != 0)
            return error.HandshakeFailed;
        c.mbedtls_ssl_set_bio(&self.ssl, self, bioSend, bioRecv, null);

        while (true) {
            const rc = c.mbedtls_ssl_handshake(&self.ssl);
            if (rc == 0) return self;
            switch (rc) {
                c.MBEDTLS_ERR_SSL_WANT_READ, c.MBEDTLS_ERR_SSL_WANT_WRITE => continue,
                else => {
                    log.warn("mbedtls_ssl_handshake failed: {d}", .{rc});
                    return error.HandshakeFailed;
                },
            }
        }
    }

    pub fn deinit(self: *Connection) void {
        if (self.initialized) {
            c.mbedtls_ssl_free(&self.ssl);
            self.initialized = false;
        }
    }

    pub fn destroy(self: *Connection) void {
        const allocator = self.server.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    /// Sends a best-effort close_notify. The peer may already be gone, so
    /// failures are ignored; the caller closes the socket afterwards.
    pub fn closeNotify(self: *Connection) void {
        if (!self.initialized) return;
        _ = c.mbedtls_ssl_close_notify(&self.ssl);
    }

    pub fn read(self: *Connection, buffer: []u8) Error!usize {
        if (buffer.len == 0) return 0;
        while (true) {
            const rc = c.mbedtls_ssl_read(&self.ssl, buffer.ptr, buffer.len);
            if (rc > 0) return @intCast(rc);
            if (self.canceled) return error.Canceled;
            switch (rc) {
                0, c.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY => return 0,
                c.MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET,
                c.MBEDTLS_ERR_SSL_WANT_READ,
                c.MBEDTLS_ERR_SSL_WANT_WRITE,
                => continue,
                c.MBEDTLS_ERR_SSL_TIMEOUT => return error.Canceled,
                else => {
                    log.debug("mbedtls_ssl_read failed: {d}", .{rc});
                    return error.ReadFailed;
                },
            }
        }
    }

    pub fn writeAll(self: *Connection, bytes: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const rc = c.mbedtls_ssl_write(&self.ssl, bytes[offset..].ptr, bytes.len - offset);
            if (rc > 0) {
                offset += @intCast(rc);
                continue;
            }
            switch (rc) {
                c.MBEDTLS_ERR_SSL_WANT_READ, c.MBEDTLS_ERR_SSL_WANT_WRITE => continue,
                else => {
                    log.debug("mbedtls_ssl_write failed: {d}", .{rc});
                    return error.WriteFailed;
                },
            }
        }
    }

    fn sendRaw(self: *Connection, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        var writer = self.stream.writer(self.io, &.{});
        try writer.interface.writeAll(bytes);
    }

    fn recvRaw(self: *Connection, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        var data: [1][]u8 = .{buffer};
        return self.stream.read(self.io, &data) catch |err| {
            if (err == error.Canceled) self.canceled = true;
            return err;
        };
    }
};

fn bioSend(ctx: ?*anyopaque, buf: [*c]const u8, len: usize) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(ctx orelse return c.MBEDTLS_ERR_NET_SEND_FAILED));
    if (len == 0) return 0;
    connection.sendRaw(buf[0..len]) catch return c.MBEDTLS_ERR_NET_SEND_FAILED;
    return @intCast(@min(len, std.math.maxInt(c_int)));
}

fn bioRecv(ctx: ?*anyopaque, buf: [*c]u8, len: usize) callconv(.c) c_int {
    const connection: *Connection = @ptrCast(@alignCast(ctx orelse return c.MBEDTLS_ERR_NET_RECV_FAILED));
    if (len == 0) return 0;
    const n = connection.recvRaw(buf[0..len]) catch return c.MBEDTLS_ERR_NET_RECV_FAILED;
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

/// `std.Io.Reader` over the decrypted stream.
pub const Reader = struct {
    connection: *Connection,
    interface: std.Io.Reader,
    err: ?Error = null,

    pub fn init(connection: *Connection, buffer: []u8) Reader {
        return .{
            .connection = connection,
            .interface = .{
                .vtable = &.{ .stream = streamImpl },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", io_r));
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        const n = self.connection.read(dest) catch |err| {
            self.err = err;
            return error.ReadFailed;
        };
        if (n == 0) return error.EndOfStream;
        io_w.advance(n);
        return n;
    }
};

/// `std.Io.Writer` over the encrypted stream.
pub const Writer = struct {
    connection: *Connection,
    interface: std.Io.Writer,
    err: ?Error = null,

    pub fn init(connection: *Connection, buffer: []u8) Writer {
        return .{
            .connection = connection,
            .interface = .{
                .vtable = &.{ .drain = drainImpl },
                .buffer = buffer,
            },
        };
    }

    fn drainImpl(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @alignCast(@fieldParentPtr("interface", io_w));

        const buffered = io_w.buffered();
        self.connection.writeAll(buffered) catch |err| {
            self.err = err;
            return error.WriteFailed;
        };
        var total = buffered.len;

        if (data.len != 0) {
            // The last slice is repeated `splat` times (std writer contract),
            // which may be zero.
            for (data, 0..) |slice, index| {
                const times = if (index + 1 == data.len) splat else 1;
                for (0..times) |_| {
                    self.connection.writeAll(slice) catch |err| {
                        self.err = err;
                        return error.WriteFailed;
                    };
                    total += slice.len;
                }
            }
        }

        return io_w.consume(total);
    }
};

test "protocol list yields the lowest and highest requested version" {
    const range = try parseProtocolRange("TLSv1.3 TLSv1.2");
    try std.testing.expectEqual(@as(c.mbedtls_ssl_protocol_version, c.MBEDTLS_SSL_VERSION_TLS1_2), range.min.?);
    try std.testing.expectEqual(@as(c.mbedtls_ssl_protocol_version, c.MBEDTLS_SSL_VERSION_TLS1_3), range.max.?);
}

test "unknown TLS protocol names are rejected" {
    try std.testing.expectError(error.UnsupportedProtocol, parseProtocolRange("TLSv1.1"));
}
