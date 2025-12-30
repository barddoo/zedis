const std = @import("std");
const Stream = std.Io.net.Stream;
const Server = @import("./server.zig");

pub const ConnectionContext = struct {
    server: *Server,
    connection: Stream,
};

pub const PrimitiveValue = union(enum) {
    string: []const u8,
    int: i64,
};
