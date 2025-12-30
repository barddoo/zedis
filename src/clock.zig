const std = @import("std");
const Io = std.Io;
const Timestamp = Io.Timestamp;
const assert = std.debug.assert;

const Clock = @This();

var ts: Timestamp = undefined;

clock_update_ms: u32,
cached: bool,
io: Io,

pub fn init(io: Io, clock_update_ms: u32) Clock {
    return .{
        .clock_update_ms = clock_update_ms,
        .cached = clock_update_ms > 0,
        .io = io,
    };
}

pub fn start(self: *Clock) !void {
    if (self.cached) {
        const thread = try std.Thread.spawn(.{}, updateLoop, .{self});
        thread.detach();
    }
}

fn updateLoop(self: *Clock) !void {
    const duration: Io.Duration = .fromMilliseconds(self.clock_update_ms);

    while (true) {
        ts = try Io.Clock.real.now(self.io);
        try Io.sleep(self.io, duration, .real);
    }
}

pub fn now(self: *Clock) Io.Clock.Error!Timestamp {
    if (self.cached) {
        return ts;
    } else {
        return Io.Clock.real.now(self.io);
    }
}
