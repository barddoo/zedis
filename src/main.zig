const std = @import("std");
const Server = @import("server.zig");
const config = @import("config.zig");
const builtin = @import("builtin");

const AllocatorContext = struct {
    allocator: std.mem.Allocator,
    gpa: if (builtin.mode == .Debug) std.heap.DebugAllocator(.{
        .stack_trace_frames = 10,
        .safety = true,
        .thread_safe = true,
    }) else void,

    fn init() AllocatorContext {
        if (builtin.mode == .Debug) {
            var ctx: AllocatorContext = undefined;
            ctx.gpa = std.heap.DebugAllocator(.{
                .stack_trace_frames = 10,
                .safety = true,
                .thread_safe = true,
            }){};
            ctx.allocator = ctx.gpa.allocator();
            return ctx;
        } else {
            return .{
                .allocator = std.heap.page_allocator,
                .gpa = {},
            };
        }
    }

    fn deinit(self: *AllocatorContext) void {
        if (builtin.mode == .Debug) {
            _ = self.gpa.deinit();
        }
    }
};

pub fn main() !void {
    var alloc_ctx = AllocatorContext.init();
    defer alloc_ctx.deinit();
    const allocator = alloc_ctx.allocator;

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
        std.log.err("Error on server {s}", .{@errorName(err)});
    };
}
