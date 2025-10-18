const std = @import("std");
const Connection = std.net.Server.Connection;
const Allocator = std.mem.Allocator;
const time = std.time;
const Store = @import("./store.zig").Store;
const CommandRegistry = @import("./commands/registry.zig").CommandRegistry;
const config_module = @import("./config.zig");
const KeyValueAllocator = @import("./kv_allocator.zig");
const Server = @import("./server.zig");

pub const ConnectionContext = struct {
    server: *Server,
    connection: std.net.Server.Connection,
};

pub const PrimitiveValue = union(enum) {
    string: []const u8,
    int: i64,
};
