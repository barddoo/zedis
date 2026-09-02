const std = @import("std");
const Io = std.Io;
const Timestamp = Io.Timestamp;

const Clock = @This();

var ts: Timestamp = undefined;

clock_update_ms: u32,
cached: bool,
io: Io,
update_task: ?Io.Future(anyerror!void) = null,

pub fn init(io: Io, clock_update_ms: u32) Clock {
    return .{
        .clock_update_ms = clock_update_ms,
        .cached = clock_update_ms > 0,
        .io = io,
    };
}

pub fn start(self: *Clock) !void {
    if (!self.cached) return;
    self.update_task = self.io.concurrent(update_loop, .{self}) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            // io backend does not support coroutines; fall back to OS thread
            const thread = try std.Thread.spawn(.{}, update_loop, .{self});
            thread.detach();
            return;
        },
        else => |e| return e,
    };
}

pub fn deinit(self: *Clock) void {
    if (self.update_task) |*task| {
        task.cancel(self.io) catch {};
        self.update_task = null;
    }
}

fn update_loop(self: *Clock) anyerror!void {
    const duration: Io.Duration = .fromMilliseconds(self.clock_update_ms);
    while (true) {
        ts = .now(self.io, .real);
        Io.sleep(self.io, duration, .real) catch |err| switch (err) {
            error.Canceled => return,
            else => |e| return e,
        };
    }
}

pub fn now(self: *Clock) Timestamp {
    if (self.cached) {
        return ts;
    } else {
        return .now(self.io, .real);
    }
}
