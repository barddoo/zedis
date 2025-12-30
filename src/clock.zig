const std = @import("std");
const Io = std.Io;
const Timestamp = Io.Timestamp;

const Clock = @This();

ts: Timestamp,
clock_update_ms: u32,
cached: bool,
io: Io,

pub fn init(io: Io, clock_update_ms: u32) Clock {
    return .{
        .ts = undefined,
        .clock_update_ms = clock_update_ms,
        .cached = clock_update_ms > 0,
        .io = io,
    };
}

pub fn start(self: *Clock) !void {
    if (self.cached) {
        // Start background thread to update timestamp
        const thread = try std.Thread.spawn(.{}, updateLoop, .{self});
        thread.detach();
    }
}

fn updateLoop(self: *Clock) !void {
    const duration: Io.Duration = .fromMilliseconds(self.clock_update_ms);

    while (true) {
        try Io.sleep(self.io, duration, .real);
        self.ts = try Io.Clock.real.now(self.io);
    }
}

pub fn now(self: *Clock) Io.Clock.Error!Timestamp {
    if (self.cached) {
        return self.ts;
    } else {
        return Io.Clock.real.now(self.io);
    }
}
