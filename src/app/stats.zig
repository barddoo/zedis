const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../protocol/parser.zig").Value;

pub const sample_ring_len = 160;
const slowlog_max_args = 32;
const slowlog_arg_max_len = 128;

/// Dataset counters maintained by the store itself, so INFO and METRICS see
/// the same numbers the eviction/expiry paths produce.
pub const StoreCounters = struct {
    keyspace_hits: u64 = 0,
    keyspace_misses: u64 = 0,
    expired_keys: u64 = 0,
    evicted_keys: u64 = 0,
};

pub const CommandStat = struct {
    calls: u64 = 0,
    usec: u64 = 0,
    errors: u64 = 0,

    pub fn usecPerCall(self: CommandStat) u64 {
        if (self.calls == 0) return 0;
        return self.usec / self.calls;
    }
};

/// Monotonic nanoseconds, the clock used for all durations. Deliberately not
/// `Server.clock`: that is a cached *wall* clock (100 ms granularity by
/// default) used for TTLs and log timestamps, and its global cache is not
/// safe from the AOF writer thread. Durations need a high-resolution monotonic
/// source, so this reads `.awake` directly.
pub fn nowNs(io: std.Io) u64 {
    const timestamp = std.Io.Clock.Timestamp.now(io, .awake);
    return @intCast(timestamp.raw.nanoseconds);
}

pub const ServerStats = struct {
    allocator: Allocator,
    commands_processed: u64 = 0,
    commands_failed: u64 = 0,
    total_net_input_bytes: u64 = 0,
    total_net_output_bytes: u64 = 0,
    rejected_connections: u64 = 0,
    rdb_changes_since_last_save: u64 = 0,
    rdb_last_save_time: i64 = 0,
    instantaneous_ops_per_sec: u64 = 0,
    last_ops_sample_ns: u64 = 0,
    last_ops_sample_commands: u64 = 0,
    per_command: std.StringHashMap(CommandStat),

    pub fn init(allocator: Allocator, io: std.Io) ServerStats {
        return .{
            .allocator = allocator,
            .per_command = std.StringHashMap(CommandStat).init(allocator),
            .last_ops_sample_ns = nowNs(io),
        };
    }

    pub fn deinit(self: *ServerStats) void {
        self.per_command.deinit();
    }

    /// Recomputes the ops/sec window. Called from the command path and from
    /// INFO/METRICS so an idle server reports a fresh (zero) rate instead of
    /// the last burst forever.
    pub fn updateOps(self: *ServerStats, io: std.Io) void {
        const now = nowNs(io);
        const elapsed = now -| self.last_ops_sample_ns;
        if (elapsed < 1_000_000_000) return;
        const delta = self.commands_processed -| self.last_ops_sample_commands;
        self.instantaneous_ops_per_sec = (delta * 1_000_000_000) / elapsed;
        self.last_ops_sample_ns = now;
        self.last_ops_sample_commands = self.commands_processed;
    }

    pub fn recordCommand(self: *ServerStats, io: std.Io, name: []const u8, duration_ns: u64, failed: bool) void {
        self.commands_processed +%= 1;
        if (failed) self.commands_failed +%= 1;

        const entry = self.per_command.getOrPut(name) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.calls +%= 1;
        entry.value_ptr.usec +%= duration_ns / 1000;
        if (failed) entry.value_ptr.errors +%= 1;

        self.updateOps(io);
    }

    pub fn reset(self: *ServerStats) void {
        self.commands_processed = 0;
        self.commands_failed = 0;
        self.total_net_input_bytes = 0;
        self.total_net_output_bytes = 0;
        self.rejected_connections = 0;
        self.instantaneous_ops_per_sec = 0;
        self.last_ops_sample_commands = 0;
        self.per_command.clearRetainingCapacity();
    }
};

pub const SlowLogEntry = struct {
    id: u64,
    timestamp: i64,
    duration_us: u64,
    args: [][]u8,
    client_addr: []u8,
    client_name: []u8,

    fn deinit(self: *SlowLogEntry, allocator: Allocator) void {
        for (self.args) |arg| allocator.free(arg);
        allocator.free(self.args);
        allocator.free(self.client_addr);
        allocator.free(self.client_name);
    }
};

/// Fixed-size ring of slow commands. Entries own their argument copies because
/// the parser's buffers are reused after the command finishes.
pub const SlowLog = struct {
    allocator: Allocator,
    entries: []SlowLogEntry = &.{},
    next: usize = 0,
    len: usize = 0,
    next_id: u64 = 0,
    /// Microseconds; a command is logged when it takes at least this long.
    /// Negative disables the log.
    threshold_us: i64 = 10_000,

    pub fn init(allocator: Allocator, max_len: usize) !SlowLog {
        if (max_len == 0) return .{ .allocator = allocator };
        return .{
            .allocator = allocator,
            .entries = try allocator.alloc(SlowLogEntry, max_len),
        };
    }

    fn liveIndex(self: *const SlowLog, index: usize) usize {
        return (self.next + self.entries.len - self.len + index) % self.entries.len;
    }

    pub fn deinit(self: *SlowLog) void {
        if (self.entries.len == 0) return;
        for (0..self.len) |index| self.entries[self.liveIndex(index)].deinit(self.allocator);
        self.allocator.free(self.entries);
        self.entries = &.{};
        self.len = 0;
        self.next = 0;
    }

    pub fn lenCount(self: *const SlowLog) usize {
        return self.len;
    }

    pub fn clear(self: *SlowLog) void {
        for (0..self.len) |index| self.entries[self.liveIndex(index)].deinit(self.allocator);
        self.next = 0;
        self.len = 0;
    }

    /// Resizes the ring, keeping the newest entries. `CONFIG SET
    /// slowlog-max-len` uses this; 0 disables the log.
    pub fn resize(self: *SlowLog, new_len: usize) !void {
        if (new_len == 0) {
            self.clear();
            if (self.entries.len > 0) self.allocator.free(self.entries);
            self.entries = &.{};
            return;
        }
        if (new_len == self.entries.len) return;

        if (self.entries.len == 0) {
            self.entries = try self.allocator.alloc(SlowLogEntry, new_len);
            self.next = 0;
            self.len = 0;
            return;
        }

        const new_entries = try self.allocator.alloc(SlowLogEntry, new_len);
        const keep = @min(self.len, new_len);
        const dropped = self.len - keep;

        // Keep the newest entries, with the oldest dropped first.
        var i: usize = 0;
        while (i < keep) : (i += 1) {
            new_entries[i] = self.entries[self.liveIndex(dropped + i)];
        }
        for (0..dropped) |index| self.entries[self.liveIndex(index)].deinit(self.allocator);

        self.allocator.free(self.entries);
        self.entries = new_entries;
        self.next = keep % new_len;
        self.len = keep;
    }

    pub fn maybeRecord(
        self: *SlowLog,
        args: []const Value,
        duration_us: u64,
        client_addr: []const u8,
        client_name: []const u8,
        now_seconds: i64,
    ) void {
        if (self.threshold_us < 0) return;
        if (self.entries.len == 0) return;
        if (duration_us < @as(u64, @intCast(self.threshold_us))) return;

        var entry: SlowLogEntry = .{
            .id = self.next_id,
            .timestamp = now_seconds,
            .duration_us = duration_us,
            .args = &.{},
            .client_addr = &.{},
            .client_name = &.{},
        };
        self.next_id +%= 1;

        entry.args = self.copyArgs(args) catch {
            self.freePartial(&entry);
            return;
        };
        entry.client_addr = if (client_addr.len == 0) &.{} else self.allocator.dupe(u8, client_addr) catch {
            self.freePartial(&entry);
            return;
        };
        entry.client_name = if (client_name.len == 0) &.{} else self.allocator.dupe(u8, client_name) catch {
            self.freePartial(&entry);
            return;
        };

        if (self.len == self.entries.len) {
            self.entries[self.next].deinit(self.allocator);
        } else {
            self.len += 1;
        }
        self.entries[self.next] = entry;
        self.next = (self.next + 1) % self.entries.len;
    }

    fn copyArgs(self: *SlowLog, args: []const Value) ![][]u8 {
        const stored = @min(args.len, slowlog_max_args);
        const extra = args.len > slowlog_max_args;
        const total = stored + @intFromBool(extra);
        const copied = try self.allocator.alloc([]u8, total);
        errdefer self.allocator.free(copied);

        var written: usize = 0;
        errdefer for (copied[0..written]) |arg| self.allocator.free(arg);

        for (args[0..stored]) |arg| {
            copied[written] = try self.truncateArg(arg.as_slice());
            written += 1;
        }
        if (extra) {
            copied[written] = try std.fmt.allocPrint(
                self.allocator,
                "... ({d} more arguments)",
                .{args.len - slowlog_max_args},
            );
            written += 1;
        }
        return copied;
    }

    fn truncateArg(self: *SlowLog, arg: []const u8) ![]u8 {
        if (arg.len <= slowlog_arg_max_len) return self.allocator.dupe(u8, arg);
        return std.fmt.allocPrint(
            self.allocator,
            "{s}... ({d} more bytes)",
            .{ arg[0..slowlog_arg_max_len], arg.len - slowlog_arg_max_len },
        );
    }

    fn freePartial(self: *SlowLog, entry: *SlowLogEntry) void {
        for (entry.args) |arg| self.allocator.free(arg);
        if (entry.args.len > 0) self.allocator.free(entry.args);
        if (entry.client_addr.len > 0) self.allocator.free(entry.client_addr);
        if (entry.client_name.len > 0) self.allocator.free(entry.client_name);
    }

    /// `index` 0 is the newest entry.
    pub fn at(self: *const SlowLog, index: usize) ?*const SlowLogEntry {
        if (index >= self.len) return null;
        const slot = (self.next + self.entries.len - 1 - index) % self.entries.len;
        return &self.entries[slot];
    }
};

pub const LatencySample = struct {
    timestamp: i64,
    latency_ms: u64,
};

pub const LatencyEvent = struct {
    name: []const u8,
    samples: [sample_ring_len]LatencySample = undefined,
    next: usize = 0,
    len: usize = 0,
    max: u64 = 0,

    pub fn record(self: *LatencyEvent, timestamp: i64, latency_ms: u64) void {
        self.samples[self.next] = .{ .timestamp = timestamp, .latency_ms = latency_ms };
        self.next = (self.next + 1) % sample_ring_len;
        if (self.len < sample_ring_len) self.len += 1;
        if (latency_ms > self.max) self.max = latency_ms;
    }

    pub fn latest(self: *const LatencyEvent) ?LatencySample {
        if (self.len == 0) return null;
        const slot = (self.next + sample_ring_len - 1) % sample_ring_len;
        return self.samples[slot];
    }

    /// Oldest first, as Redis' LATENCY HISTORY returns it.
    pub fn history(self: *const LatencyEvent, out: []LatencySample) []LatencySample {
        const count = @min(self.len, out.len);
        const start = if (self.len < sample_ring_len) 0 else self.next;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            out[i] = self.samples[(start + i) % sample_ring_len];
        }
        return out[0..count];
    }

    pub fn reset(self: *LatencyEvent) void {
        self.next = 0;
        self.len = 0;
        self.max = 0;
    }
};

pub const LatencyMonitor = struct {
    /// Milliseconds; 0 disables recording.
    threshold_ms: u64 = 0,
    events: [3]LatencyEvent = .{
        .{ .name = "command" },
        .{ .name = "aof-fsync-always" },
        .{ .name = "expire-cycle" },
    },

    pub fn record(self: *LatencyMonitor, event_name: []const u8, timestamp: i64, latency_ms: u64) void {
        if (self.threshold_ms == 0 or latency_ms < self.threshold_ms) return;
        const event = self.get(event_name) orelse return;
        event.record(timestamp, latency_ms);
    }

    pub fn recordUnconditional(self: *LatencyMonitor, event_name: []const u8, timestamp: i64, latency_ms: u64) void {
        const event = self.get(event_name) orelse return;
        event.record(timestamp, latency_ms);
    }

    pub fn get(self: *LatencyMonitor, event_name: []const u8) ?*LatencyEvent {
        for (&self.events) |*event| {
            if (std.mem.eql(u8, event.name, event_name)) return event;
        }
        return null;
    }

    pub fn getConst(self: *const LatencyMonitor, event_name: []const u8) ?*const LatencyEvent {
        for (&self.events) |*event| {
            if (std.mem.eql(u8, event.name, event_name)) return event;
        }
        return null;
    }

    pub fn reset(self: *LatencyMonitor, event_name: ?[]const u8) usize {
        var count: usize = 0;
        for (&self.events) |*event| {
            if (event_name) |name| {
                if (!std.mem.eql(u8, event.name, name)) continue;
            }
            event.reset();
            count += 1;
        }
        return count;
    }
};

test "slowlog keeps newest entries and truncates long arguments" {
    var slowlog = try SlowLog.init(std.testing.allocator, 2);
    defer slowlog.deinit();

    var long_arg: [200]u8 = undefined;
    @memset(&long_arg, 'x');
    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key" },
        .{ .data = &long_arg },
    };

    slowlog.maybeRecord(&args, 20_000, "127.0.0.1:1", "", 1);
    slowlog.maybeRecord(&args, 20_000, "127.0.0.1:2", "", 2);
    slowlog.maybeRecord(&args, 20_000, "127.0.0.1:3", "", 3);

    try std.testing.expectEqual(@as(usize, 2), slowlog.lenCount());
    const newest = slowlog.at(0).?;
    try std.testing.expectEqual(@as(i64, 3), newest.timestamp);
    try std.testing.expectEqualStrings("127.0.0.1:3", newest.client_addr);
    try std.testing.expect(std.mem.endsWith(u8, newest.args[2], "... (72 more bytes)"));
}

test "slowlog reports more arguments than it stores" {
    var slowlog = try SlowLog.init(std.testing.allocator, 4);
    defer slowlog.deinit();

    var args: [40]Value = undefined;
    for (&args, 0..) |*arg, i| {
        var buf: [8]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "a{d}", .{i});
        arg.* = .{ .data = text };
    }

    slowlog.maybeRecord(&args, 20_000, "", "", 1);
    const entry = slowlog.at(0).?;
    try std.testing.expectEqual(@as(usize, slowlog_max_args + 1), entry.args.len);
    try std.testing.expectEqualStrings("... (8 more arguments)", entry.args[slowlog_max_args]);
}

test "slowlog survives being disabled and re-enabled at runtime" {
    var slowlog = try SlowLog.init(std.testing.allocator, 2);
    defer slowlog.deinit();

    const args = [_]Value{.{ .data = "PING" }};
    slowlog.maybeRecord(&args, 20_000, "", "", 1);
    try std.testing.expectEqual(@as(usize, 1), slowlog.lenCount());

    try slowlog.resize(0);
    try std.testing.expectEqual(@as(usize, 0), slowlog.lenCount());

    try slowlog.resize(3);
    try std.testing.expectEqual(@as(usize, 0), slowlog.lenCount());
    slowlog.maybeRecord(&args, 20_000, "", "", 2);
    try std.testing.expectEqual(@as(usize, 1), slowlog.lenCount());
}

test "shrinking the slowlog keeps the newest entries" {
    var slowlog = try SlowLog.init(std.testing.allocator, 3);
    defer slowlog.deinit();

    const args = [_]Value{.{ .data = "PING" }};
    slowlog.maybeRecord(&args, 20_000, "", "", 1);
    slowlog.maybeRecord(&args, 20_000, "", "", 2);
    slowlog.maybeRecord(&args, 20_000, "", "", 3);

    try slowlog.resize(1);

    try std.testing.expectEqual(@as(usize, 1), slowlog.lenCount());
    try std.testing.expectEqual(@as(i64, 3), slowlog.at(0).?.timestamp);
}

test "latency monitor stores history oldest first and caps at the threshold" {
    var monitor = LatencyMonitor{ .threshold_ms = 10 };
    monitor.record("command", 1, 5);
    monitor.record("command", 2, 12);
    monitor.record("command", 3, 20);

    const event = monitor.get("command").?;
    try std.testing.expectEqual(@as(usize, 2), event.len);
    try std.testing.expectEqual(@as(u64, 20), event.max);
    try std.testing.expectEqual(@as(i64, 3), event.latest().?.timestamp);

    var buffer: [sample_ring_len]LatencySample = undefined;
    const history = event.history(&buffer);
    try std.testing.expectEqual(@as(i64, 2), history[0].timestamp);
    try std.testing.expectEqual(@as(i64, 3), history[1].timestamp);
}

test "ops rate is recomputed only after a full second" {
    var stats = ServerStats.init(std.testing.allocator, std.testing.io);
    defer stats.deinit();

    stats.commands_processed = 10;
    stats.last_ops_sample_ns = nowNs(std.testing.io) -| 2_000_000_000;
    stats.last_ops_sample_commands = 0;
    stats.updateOps(std.testing.io);
    try std.testing.expect(stats.instantaneous_ops_per_sec > 0);
    try std.testing.expect(stats.instantaneous_ops_per_sec <= 10);
}
