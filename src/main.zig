const std = @import("std");
const Server = @import("server.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = config.readConfig(allocator) catch |err| {
        std.log.err("Error reading config: {s}", .{@errorName(err)});
        return;
    };

    // Create and start the server with configuration
    var redis_server = Server.initWithConfig(allocator, cfg.host, cfg.port, cfg) catch |err| {
        std.log.err("Error server init: {s}", .{@errorName(err)});
        return;
    };
    defer redis_server.deinit();

    std.log.info("Zig Redis server listening on {s}:{d}", .{ cfg.host, cfg.port });

    redis_server.listen() catch |err| {
        std.log.err("Error on server {any}", .{@errorName(err)});
    };
}
