//! Server-side TLS for client connections, backed by OpenSSL.
//!
//! OpenSSL is driven through memory BIOs: every socket read/write stays in
//! Zig, so zio can suspend the calling coroutine instead of blocking the
//! executor. The `Connection` owns one `SSL` object and both BIOs; zio
//! serializes writes per client with the client's write mutex, so an SSL
//! object is only touched by one coroutine at a time.

const std = @import("std");

const Io = std.Io;
const Stream = Io.net.Stream;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.tls);

const OpenSslCtx = opaque {};
const OpenSslConn = opaque {};

extern fn zedis_tls_ctx_new(
    cert_file: [*:0]const u8,
    key_file: [*:0]const u8,
    ca_file: [*:0]const u8,
    auth_clients: c_int,
    min_version: c_int,
    max_version: c_int,
    err: [*]u8,
    err_len: usize,
) ?*OpenSslCtx;
extern fn zedis_tls_ctx_free(ctx: *OpenSslCtx) void;
extern fn zedis_tls_conn_new(ctx: *OpenSslCtx, err: [*]u8, err_len: usize) ?*OpenSslConn;
extern fn zedis_tls_conn_free(conn: *OpenSslConn) void;
extern fn zedis_tls_conn_error(conn: *OpenSslConn) [*:0]const u8;
extern fn zedis_tls_version_1_2() c_int;
extern fn zedis_tls_version_1_3() c_int;
extern fn zedis_tls_handshake(conn: *OpenSslConn) c_int;
extern fn zedis_tls_feed(conn: *OpenSslConn, data: *const anyopaque, len: usize) c_int;
extern fn zedis_tls_pending(conn: *OpenSslConn) c_int;
extern fn zedis_tls_flush(conn: *OpenSslConn, buf: [*]u8, cap: usize) c_int;
extern fn zedis_tls_read(conn: *OpenSslConn, buf: [*]u8, len: usize) c_int;
extern fn zedis_tls_write(conn: *OpenSslConn, buf: *const anyopaque, len: usize) c_int;
extern fn zedis_tls_shutdown(conn: *OpenSslConn) void;

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
    ConfigFailed,
    UnsupportedProtocol,
    OutOfMemory,
};

/// Process-wide TLS configuration shared by every accepted connection.
pub const Server = struct {
    allocator: Allocator,
    ctx: *OpenSslCtx,

    pub fn create(allocator: Allocator, options: Options) InitError!*Server {
        if (options.cert_file.len == 0) return error.MissingCertFile;
        if (options.key_file.len == 0) return error.MissingKeyFile;
        if (options.auth_clients != .no and options.ca_file.len == 0) return error.MissingCaCertFile;

        const range = try parseProtocolRange(options.protocols);
        const auth: c_int = switch (options.auth_clients) {
            .no => 0,
            .optional => 1,
            .required => 2,
        };

        const cert = try allocator.dupeSentinel(u8, options.cert_file, 0);
        defer allocator.free(cert);
        const key = try allocator.dupeSentinel(u8, options.key_file, 0);
        defer allocator.free(key);
        const ca = try allocator.dupeSentinel(u8, options.ca_file, 0);
        defer allocator.free(ca);

        var err: [256]u8 = undefined;
        err[0] = 0;
        const ctx = zedis_tls_ctx_new(
            cert.ptr,
            key.ptr,
            ca.ptr,
            auth,
            range.min orelse 0,
            range.max orelse 0,
            &err,
            err.len,
        ) orelse {
            log.err("OpenSSL configuration failed: {s}", .{std.mem.sliceTo(&err, 0)});
            return error.ConfigFailed;
        };

        const self = try allocator.create(Server);
        self.* = .{ .allocator = allocator, .ctx = ctx };
        return self;
    }

    pub fn destroy(self: *Server) void {
        const allocator = self.allocator;
        zedis_tls_ctx_free(self.ctx);
        allocator.destroy(self);
    }
};

pub const Error = error{
    HandshakeFailed,
    ReadFailed,
    WriteFailed,
    Canceled,
};

/// One TLS-wrapped client socket. Allocated on the heap so the SSL context has
/// a stable address for its lifetime.
pub const Connection = struct {
    stream: Stream,
    io: Io,
    server: *Server,
    conn: *OpenSslConn,

    pub fn accept(stream: Stream, io: Io, server: *Server) Error!*Connection {
        const allocator = server.allocator;
        const self = allocator.create(Connection) catch return error.HandshakeFailed;

        var err: [256]u8 = undefined;
        err[0] = 0;
        const conn = zedis_tls_conn_new(server.ctx, &err, err.len) orelse {
            allocator.destroy(self);
            log.warn("OpenSSL connection setup failed: {s}", .{std.mem.sliceTo(&err, 0)});
            return error.HandshakeFailed;
        };
        self.* = .{
            .stream = stream,
            .io = io,
            .server = server,
            .conn = conn,
        };
        errdefer {
            zedis_tls_conn_free(conn);
            allocator.destroy(self);
        }

        try self.handshake();
        return self;
    }

    pub fn destroy(self: *Connection) void {
        const allocator = self.server.allocator;
        zedis_tls_conn_free(self.conn);
        allocator.destroy(self);
    }

    /// Sends a best-effort close_notify. The peer may already be gone, so
    /// failures are ignored; the caller closes the socket afterwards.
    pub fn closeNotify(self: *Connection) void {
        zedis_tls_shutdown(self.conn);
        self.flushOut() catch {};
    }

    pub fn read(self: *Connection, buffer: []u8) Error!usize {
        if (buffer.len == 0) return 0;
        while (true) {
            const rc = zedis_tls_read(self.conn, buffer.ptr, buffer.len);
            if (rc > 0) return @intCast(rc);
            if (rc == 0) return 0;
            if (rc == -2) {
                // Key updates and alerts may be queued for the peer before we
                // block waiting for more ciphertext.
                try self.flushOut();
                if (!try self.fillInput()) return 0;
                continue;
            }
            if (rc == -3) {
                try self.flushOut();
                continue;
            }
            log.debug("OpenSSL read failed: {s}", .{self.lastError()});
            return error.ReadFailed;
        }
    }

    pub fn writeAll(self: *Connection, bytes: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const rc = zedis_tls_write(self.conn, bytes[offset..].ptr, bytes.len - offset);
            if (rc > 0) {
                offset += @intCast(rc);
                if (zedis_tls_pending(self.conn) >= 64 * 1024) try self.flushOut();
                continue;
            }
            if (rc == -3) {
                try self.flushOut();
                continue;
            }
            if (rc == -2) {
                try self.flushOut();
                if (!try self.fillInput()) return error.WriteFailed;
                continue;
            }
            log.debug("OpenSSL write failed: {s}", .{self.lastError()});
            return error.WriteFailed;
        }
        try self.flushOut();
    }

    fn handshake(self: *Connection) Error!void {
        while (true) {
            const rc = zedis_tls_handshake(self.conn);
            if (rc == 1) return;
            if (rc < 0) {
                log.warn("OpenSSL handshake failed: {s}", .{self.lastError()});
                return error.HandshakeFailed;
            }
            if (zedis_tls_pending(self.conn) > 0) {
                try self.flushOut();
                continue;
            }
            if (!try self.fillInput()) return error.HandshakeFailed;
        }
    }

    fn flushOut(self: *Connection) Error!void {
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const rc = zedis_tls_flush(self.conn, &buffer, buffer.len);
            if (rc < 0) return error.WriteFailed;
            if (rc == 0) return;
            try self.sendRaw(buffer[0..@intCast(rc)]);
        }
    }

    fn fillInput(self: *Connection) Error!bool {
        var buffer: [16 * 1024]u8 = undefined;
        const n = self.recvRaw(&buffer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.ReadFailed,
        };
        if (n == 0) return false;
        if (zedis_tls_feed(self.conn, &buffer, n) != 0) return error.ReadFailed;
        return true;
    }

    fn lastError(self: *Connection) []const u8 {
        return std.mem.span(zedis_tls_conn_error(self.conn));
    }

    fn sendRaw(self: *Connection, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        var writer = self.stream.writer(self.io, &.{});
        try writer.interface.writeAll(bytes);
    }

    fn recvRaw(self: *Connection, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        var data: [1][]u8 = .{buffer};
        return self.stream.read(self.io, &data);
    }
};

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

const ProtocolRange = struct {
    min: ?c_int = null,
    max: ?c_int = null,
};

fn parseProtocolRange(protocols: []const u8) error{UnsupportedProtocol}!ProtocolRange {
    var range: ProtocolRange = .{};
    var tokens = std.mem.tokenizeAny(u8, protocols, " \t,");
    while (tokens.next()) |token| {
        const version: c_int = if (std.mem.eql(u8, token, "TLSv1.2"))
            zedis_tls_version_1_2()
        else if (std.mem.eql(u8, token, "TLSv1.3"))
            zedis_tls_version_1_3()
        else
            return error.UnsupportedProtocol;

        range.min = if (range.min) |current| @min(current, version) else version;
        range.max = if (range.max) |current| @max(current, version) else version;
    }
    return range;
}

test "protocol list yields the lowest and highest requested version" {
    const range = try parseProtocolRange("TLSv1.3 TLSv1.2");
    try std.testing.expectEqual(zedis_tls_version_1_2(), range.min.?);
    try std.testing.expectEqual(zedis_tls_version_1_3(), range.max.?);
}

test "unknown TLS protocol names are rejected" {
    try std.testing.expectError(error.UnsupportedProtocol, parseProtocolRange("TLSv1.1"));
}
