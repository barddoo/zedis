const std = @import("std");
const Server = @import("server.zig");
const config = @import("config.zig");
const builtin = @import("builtin");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = .init(allocator);
    const io = threaded.io();

    const cfg = config.readConfig(allocator, io) catch |err| {
        std.log.err("Failed to read config: {s}", .{@errorName(err)});
        return err;
    };

    // Create and start the server with configuration
    var redis_server = Server.initWithConfig(allocator, cfg.host, cfg.port, cfg, io) catch |err| {
        std.log.err("Failed to initialize server: {s}", .{@errorName(err)});
        return err;
    };
    defer redis_server.deinit();

    std.log.info("Zedis server listening on {s}:{d}", .{ cfg.host, cfg.port });

    redis_server.listen() catch |err| {
        std.log.err("Server error: {s}", .{@errorName(err)});
        return err;
    };
}
