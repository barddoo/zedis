//! Server-side TLS for client connections, backed by ztls.
//!
//! ztls runs the record layer in Zig and does its I/O through `std.Io`
//! readers and writers, so waiting on the peer suspends the calling zio
//! coroutine instead of blocking the executor. The ciphertext reader and
//! writer live in `Connection` next to the heap-allocated `ztls.Connection`,
//! which keeps pointers to both for the life of the connection.

const std = @import("std");
const ztls = @import("ztls");

const Io = std.Io;
const Stream = Io.net.Stream;
const Allocator = std.mem.Allocator;
const proto = ztls.protocol;
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
    ConfigFailed,
    UnsupportedProtocol,
    OutOfMemory,
};

/// Process-wide TLS configuration shared by every accepted connection.
pub const Server = struct {
    allocator: Allocator,
    /// Chain and key presented to clients.
    auth: ztls.CertKeyPair,
    /// Trust anchors for client certificates; empty unless `ca_file` was set.
    trust: ztls.TrustStore,
    /// Null when clients need not present a certificate.
    client_auth: ?ztls.config.ClientAuth.Type,
    min_version: ?proto.Version,
    max_version: ?proto.Version,

    pub fn create(io: Io, allocator: Allocator, options: Options) InitError!*Server {
        if (options.cert_file.len == 0) return error.MissingCertFile;
        if (options.key_file.len == 0) return error.MissingKeyFile;
        if (options.auth_clients != .no and options.ca_file.len == 0) return error.MissingCaCertFile;

        const range = try parseProtocolRange(options.protocols);

        var auth = ztls.CertKeyPair.fromFilePath(allocator, io, .cwd(), options.cert_file, options.key_file) catch |err| {
            log.err("failed to load TLS certificate or key: {s}", .{@errorName(err)});
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ConfigFailed,
            };
        };
        errdefer auth.deinit(allocator);

        var trust = ztls.TrustStore.init() catch |err| {
            log.err("failed to create TLS trust store: {s}", .{@errorName(err)});
            return error.ConfigFailed;
        };
        errdefer trust.deinit();

        if (options.ca_file.len != 0) {
            trust.addPemFile(allocator, io, .cwd(), options.ca_file) catch |err| {
                log.err("failed to load TLS CA certificates: {s}", .{@errorName(err)});
                return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.ConfigFailed,
                };
            };
        }

        const self = allocator.create(Server) catch return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .auth = auth,
            .trust = trust,
            .client_auth = switch (options.auth_clients) {
                .no => null,
                .optional => .request,
                .required => .require,
            },
            .min_version = range.min,
            .max_version = range.max,
        };
        return self;
    }

    pub fn destroy(self: *Server) void {
        const allocator = self.allocator;
        self.auth.deinit(allocator);
        self.trust.deinit();
        allocator.destroy(self);
    }
};

pub const Error = error{
    HandshakeFailed,
    Canceled,
};

/// Decrypted stream over the TLS connection. ztls keeps no per-buffer state,
/// so a writer may be created per write and a reader per reading task.
pub const Reader = ztls.Connection.Reader;
pub const Writer = ztls.Connection.Writer;

/// One TLS-wrapped client socket. Heap-allocated because ztls keeps pointers
/// into the ciphertext reader and writer, and the connection must not move
/// after a reader or writer is made from it.
pub const Connection = struct {
    stream: Stream,
    io: Io,
    server: *Server,
    /// Ciphertext buffers. ztls requires one whole record in each.
    input_buffer: [ztls.input_buffer_len]u8,
    output_buffer: [ztls.output_buffer_len]u8,
    input: Stream.Reader,
    output: Stream.Writer,
    conn: ztls.Connection,

    pub fn accept(stream: Stream, io: Io, server: *Server) Error!*Connection {
        const allocator = server.allocator;
        const self = allocator.create(Connection) catch return error.HandshakeFailed;
        errdefer allocator.destroy(self);

        self.stream = stream;
        self.io = io;
        self.server = server;
        self.input = stream.reader(io, &self.input_buffer);
        self.output = stream.writer(io, &self.output_buffer);

        const client_auth: ?ztls.config.ClientAuth = if (server.client_auth) |auth_type|
            .{ .root_ca = &server.trust, .auth_type = auth_type }
        else
            null;

        self.conn = ztls.server(&self.input.interface, &self.output.interface, .{
            .io = io,
            .gpa = allocator,
            .auth = &server.auth,
            .client_auth = client_auth,
            .min_version = server.min_version,
            .max_version = server.max_version,
        }) catch |err| {
            log.warn("TLS handshake failed: {s}", .{@errorName(err)});
            return error.HandshakeFailed;
        };
        return self;
    }

    pub fn destroy(self: *Connection) void {
        const allocator = self.server.allocator;
        self.conn.deinit();
        allocator.destroy(self);
    }

    /// Sends a best-effort close_notify. The peer may already be gone, so
    /// failures are ignored; the caller closes the socket afterwards.
    pub fn closeNotify(self: *Connection) void {
        self.conn.close() catch {};
    }

    pub fn reader(self: *Connection, buffer: []u8) Reader {
        return self.conn.reader(buffer);
    }

    pub fn writer(self: *Connection, buffer: []u8) Writer {
        return self.conn.writer(buffer);
    }
};

const ProtocolRange = struct {
    min: ?proto.Version = null,
    max: ?proto.Version = null,
};

fn parseProtocolRange(protocols: []const u8) error{UnsupportedProtocol}!ProtocolRange {
    var range: ProtocolRange = .{};
    var tokens = std.mem.tokenizeAny(u8, protocols, " \t,");
    while (tokens.next()) |token| {
        const version: proto.Version = if (std.mem.eql(u8, token, "TLSv1.2"))
            .tls_1_2
        else if (std.mem.eql(u8, token, "TLSv1.3"))
            .tls_1_3
        else
            return error.UnsupportedProtocol;

        range.min = if (range.min) |current| lower(current, version) else version;
        range.max = if (range.max) |current| higher(current, version) else version;
    }

    // ztls' native server speaks TLS 1.3 only, so a range that excludes it
    // has nothing left to negotiate.
    if (range.max) |max| {
        if (@backingInt(max) < @backingInt(proto.Version.tls_1_3)) return error.UnsupportedProtocol;
    }
    return range;
}

fn lower(a: proto.Version, b: proto.Version) proto.Version {
    return if (@backingInt(a) <= @backingInt(b)) a else b;
}

fn higher(a: proto.Version, b: proto.Version) proto.Version {
    return if (@backingInt(a) >= @backingInt(b)) a else b;
}

test "protocol list yields the lowest and highest requested version" {
    const range = try parseProtocolRange("TLSv1.3 TLSv1.2");
    try std.testing.expectEqual(proto.Version.tls_1_2, range.min.?);
    try std.testing.expectEqual(proto.Version.tls_1_3, range.max.?);
}

test "unknown TLS protocol names are rejected" {
    try std.testing.expectError(error.UnsupportedProtocol, parseProtocolRange("TLSv1.1"));
}

test "a range without TLS 1.3 is rejected by the native engine" {
    try std.testing.expectError(error.UnsupportedProtocol, parseProtocolRange("TLSv1.2"));
}
