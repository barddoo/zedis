const std = @import("std");
const store_mod = @import("../storage/store.zig");
const Store = store_mod.Store;
const ZedisValue = store_mod.ZedisValue;
const ZedisList = @import("../storage/list.zig").ZedisList;
const ZedisListNode = @import("../storage/list.zig").ZedisListNode;
const ZedisHash = @import("../storage/hash.zig").ZedisHash;
const ZedisSet = @import("../storage/set.zig").ZedisSet;
const ZedisZSet = @import("../storage/zset.zig").ZedisZSet;
const TimeSeries = @import("../storage/time_series.zig").TimeSeries;
const Io = std.Io;

const log = std.log.scoped(.aof);

/// Elements per RPUSH: bounds each command without one command per element.
const list_chunk = 64;

/// Writes the dataset as the shortest command sequence that rebuilds it, in
/// the AOF's own RESP framing, so a rewritten AOF replays like any other.
///
/// Fails with `error.UnsupportedType` before writing anything if the store
/// holds a value no command sequence can recreate (a bloom filter is a bit
/// array, not a list of items), so the caller keeps its old AOF.
pub fn write(store: *const Store, now_ms: i64, writer: *Io.Writer) !void {
    try check_supported(store);

    var it = store.iterator();
    while (it.next()) |entry| {
        if (entry.expires_at) |at| {
            if (at <= now_ms) continue;
        }
        try write_value(writer, entry.key, entry.object.value);
        if (entry.expires_at) |at| {
            var buf: [24]u8 = undefined;
            try put(writer, &.{ "PEXPIREAT", entry.key, int_text(&buf, at) });
        }
    }
}

fn check_supported(store: *const Store) error{UnsupportedType}!void {
    var it = store.iterator();
    while (it.next()) |entry| {
        switch (entry.object.value) {
            .string, .short_string, .int, .list, .time_series, .hash_map, .set, .zset => {},
            .bloom_filter, .search_index => {
                log.warn("AOF rewrite cannot express {s} key '{s}'", .{ @tagName(entry.object.value), entry.key });
                return error.UnsupportedType;
            },
        }
    }
}

fn write_value(writer: *Io.Writer, key: []const u8, value: ZedisValue) !void {
    var buf: [24]u8 = undefined;
    switch (value) {
        .string => |s| try put(writer, &.{ "SET", key, s }),
        .short_string => |ss| try put(writer, &.{ "SET", key, ss.as_slice() }),
        .int => |i| try put(writer, &.{ "SET", key, int_text(&buf, i) }),
        .list => |list| try write_list(writer, key, list),
        .time_series => |ts| try write_time_series(writer, key, ts),
        .hash_map => |h| try write_hash(writer, key, h),
        .set => |s| try write_set(writer, key, s),
        .zset => |z| try write_zset(writer, key, z),
        .bloom_filter, .search_index => unreachable,
    }
}

fn write_list(writer: *Io.Writer, key: []const u8, list: *ZedisList) !void {
    var parts: [2 + list_chunk][]const u8 = undefined;
    var int_bufs: [list_chunk][24]u8 = undefined;
    parts[0] = "RPUSH";
    parts[1] = key;

    var n: usize = 0;
    var current = list.list.first;
    while (current) |node| : (current = node.next) {
        const item: *ZedisListNode = @fieldParentPtr("node", node);
        // Captured by pointer: the slice must outlive this switch.
        parts[2 + n] = switch (item.data) {
            .string => |s| s,
            .short_string => |*ss| ss.as_slice(),
            .int => |i| int_text(&int_bufs[n], i),
        };
        n += 1;
        if (n == list_chunk) {
            try put(writer, parts[0 .. 2 + n]);
            n = 0;
        }
    }
    if (n > 0) try put(writer, parts[0 .. 2 + n]);
}

fn write_time_series(writer: *Io.Writer, key: []const u8, ts: *const TimeSeries) !void {
    var retention_buf: [24]u8 = undefined;
    var chunk_buf: [24]u8 = undefined;
    var time_diff_buf: [24]u8 = undefined;
    var value_diff_buf: [400]u8 = undefined;

    var parts: [16][]const u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{
        "TS.CREATE",
        key,
        "RETENTION",
        int_text(&retention_buf, ts.retention_ms),
        "CHUNK_SIZE",
        int_text(&chunk_buf, ts.max_chunk_samples),
        "ENCODING",
        if (ts.encoding == .Uncompressed) "UNCOMPRESSED" else "COMPRESSED",
        "DUPLICATE_POLICY",
        @tagName(ts.duplicate_policy),
    }) |part| {
        parts[n] = part;
        n += 1;
    }
    if (ts.ignore_max_time_diff != 0 or ts.ignore_max_val_diff != 0) {
        parts[n] = "IGNORE";
        parts[n + 1] = int_text(&time_diff_buf, ts.ignore_max_time_diff);
        parts[n + 2] = try std.fmt.bufPrint(&value_diff_buf, "{d}", .{ts.ignore_max_val_diff});
        n += 3;
    }
    try put(writer, parts[0..n]);

    var samples = try ts.range("-", "+", null, null);
    defer samples.deinit(ts.allocator);
    for (samples.items) |sample| {
        // Formatted straight into the frame: a float can run to hundreds of
        // digits, so it has no fixed-size buffer.
        try writer.print("*4\r\n$6\r\nTS.ADD\r\n${d}\r\n{s}\r\n${d}\r\n{d}\r\n${d}\r\n{d}\r\n", .{
            key.len,
            key,
            std.fmt.count("{d}", .{sample.timestamp}),
            sample.timestamp,
            std.fmt.count("{d}", .{sample.value}),
            sample.value,
        });
    }
}

/// Pairs per HSET command when chunking a large hash.
const hash_chunk = 64;

fn write_hash(writer: *Io.Writer, key: []const u8, h: *const ZedisHash) !void {
    // Each command is: HSET key [field value] * N
    // Max args = 2 + hash_chunk * 2.
    var parts: [2 + hash_chunk * 2][]const u8 = undefined;
    var int_bufs: [hash_chunk][24]u8 = undefined;
    parts[0] = "HSET";
    parts[1] = key;

    var n: usize = 0;
    var it = h.iterator();
    while (it.next()) |entry| {
        parts[2 + n * 2] = entry.key_ptr.*;
        parts[2 + n * 2 + 1] = switch (entry.value_ptr.*) {
            .string => |s| s,
            .short_string => |*ss| ss.as_slice(),
            .int => |i| int_text(&int_bufs[n], i),
        };
        n += 1;
        if (n == hash_chunk) {
            try put(writer, parts[0 .. 2 + n * 2]);
            n = 0;
        }
    }
    if (n > 0) try put(writer, parts[0 .. 2 + n * 2]);
}

/// Members per SADD/ZADD command when chunking a large set or zset.
const set_chunk = 64;

fn write_set(writer: *Io.Writer, key: []const u8, s: *const ZedisSet) !void {
    var parts: [2 + set_chunk][]const u8 = undefined;
    parts[0] = "SADD";
    parts[1] = key;

    var n: usize = 0;
    var it = s.iterator();
    while (it.next()) |member| {
        parts[2 + n] = member.*;
        n += 1;
        if (n == set_chunk) {
            try put(writer, parts[0 .. 2 + n]);
            n = 0;
        }
    }
    if (n > 0) try put(writer, parts[0 .. 2 + n]);
}

fn write_zset(writer: *Io.Writer, key: []const u8, z: *const ZedisZSet) !void {
    var parts: [2 + set_chunk * 2][]const u8 = undefined;
    var score_bufs: [set_chunk][32]u8 = undefined;
    parts[0] = "ZADD";
    parts[1] = key;

    var n: usize = 0;
    for (z.order.items) |entry| {
        // {d} prints the shortest text that parses back to the same f64.
        parts[2 + n * 2] = std.fmt.bufPrint(&score_bufs[n], "{d}", .{entry.score}) catch unreachable;
        parts[2 + n * 2 + 1] = entry.member;
        n += 1;
        if (n == set_chunk) {
            try put(writer, parts[0 .. 2 + n * 2]);
            n = 0;
        }
    }
    if (n > 0) try put(writer, parts[0 .. 2 + n * 2]);
}

fn put(writer: *Io.Writer, parts: []const []const u8) Io.Writer.Error!void {
    try writer.print("*{d}\r\n", .{parts.len});
    for (parts) |part| {
        try writer.print("${d}\r\n", .{part.len});
        try writer.writeAll(part);
        try writer.writeAll("\r\n");
    }
}

fn int_text(buf: *[24]u8, value: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
}

const testing = std.testing;
const Parser = @import("../protocol/parser.zig");
const Value = Parser.Value;
const Registry = @import("../commands/registry.zig").CommandRegistry;
const Clock = @import("../app/clock.zig");

const TestStore = struct {
    registry: Registry,
    clock: Clock,
    store: Store,

    fn init(self: *TestStore) !void {
        self.registry = try @import("../commands/init_registry.zig").init_registry(testing.allocator);
        self.clock = Clock.init(testing.io, 0);
        self.store = try Store.init(testing.allocator, testing.io, &self.clock, .{ .initial_capacity = 4096 });
    }

    fn deinit(self: *TestStore) void {
        self.store.deinit();
        self.registry.deinit();
    }

    fn run(self: *TestStore, argv: []const []const u8) !void {
        var args: [16]Value = undefined;
        for (argv, 0..) |arg, i| args[i] = .{ .data = arg };
        try self.registry.execute_command_aof(&self.store, args[0..argv.len]);
    }

    fn now_ms(self: *TestStore) i64 {
        return self.clock.now().toMilliseconds();
    }

    /// Replays RESP command bytes into this store.
    fn replay(self: *TestStore, bytes: []const u8) !void {
        var reader: Io.Reader = .fixed(bytes);
        var parser = Parser.init(testing.allocator);
        while (reader.bufferedLen() > 0) {
            var command = try parser.parse(&reader);
            defer command.deinit();
            try self.registry.execute_command_aof(&self.store, command.get_args());
        }
    }
};

fn dump(source: *TestStore, out: *Io.Writer.Allocating) !void {
    try write(&source.store, source.now_ms(), &out.writer);
}

test "snapshot writes each value type as the commands that recreate it" {
    var source: TestStore = undefined;
    try source.init();
    defer source.deinit();

    try source.run(&.{ "SET", "text", "hello" });
    try source.run(&.{ "INCR", "counter" });
    try source.run(&.{ "INCR", "counter" });
    try source.run(&.{ "RPUSH", "queue", "a", "b", "7" });

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump(&source, &out);

    var copy: TestStore = undefined;
    try copy.init();
    defer copy.deinit();
    try copy.replay(out.written());

    try testing.expectEqual(@as(usize, 3), copy.store.size());
    try testing.expectEqualStrings("hello", copy.store.get("text").?.value.short_string.as_slice());
    try copy.run(&.{ "INCR", "counter" });
    try testing.expectEqual(@as(i64, 3), copy.store.get("counter").?.value.int);
    try testing.expectEqual(@as(usize, 3), copy.store.get("queue").?.value.list.len());
}

test "snapshot rebuilds sets and sorted sets across chunk boundaries with exact scores" {
    var source: TestStore = undefined;
    try source.init();
    defer source.deinit();

    var member: [16]u8 = undefined;
    const total = set_chunk * 2 + 3;
    for (0..total) |i| {
        const name = try std.fmt.bufPrint(&member, "m-{d}", .{i});
        try source.run(&.{ "SADD", "tags", name });
        var score: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&score, "{d}", .{@as(f64, @floatFromInt(i)) / 3.0});
        try source.run(&.{ "ZADD", "scheduled", text, name });
    }

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump(&source, &out);

    var copy: TestStore = undefined;
    try copy.init();
    defer copy.deinit();
    try copy.replay(out.written());

    try testing.expectEqual(total, copy.store.get("tags").?.value.set.len());
    const original = source.store.get("scheduled").?.value.zset;
    const rebuilt = copy.store.get("scheduled").?.value.zset;
    try testing.expectEqual(original.len(), rebuilt.len());
    for (original.order.items, rebuilt.order.items) |a, b| {
        try testing.expectEqualStrings(a.member, b.member);
        try testing.expectEqual(a.score, b.score);
    }
}

test "snapshot keeps lists in order across RPUSH chunk boundaries" {
    var source: TestStore = undefined;
    try source.init();
    defer source.deinit();

    var buf: [16]u8 = undefined;
    const total = list_chunk * 2 + 5;
    for (0..total) |i| {
        try source.run(&.{ "RPUSH", "long", try std.fmt.bufPrint(&buf, "item-{d}", .{i}) });
    }

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump(&source, &out);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, out.written(), "RPUSH"));

    var copy: TestStore = undefined;
    try copy.init();
    defer copy.deinit();
    try copy.replay(out.written());

    const list = copy.store.get("long").?.value.list;
    try testing.expectEqual(@as(usize, total), list.len());
    var node = list.list.first;
    for (0..total) |i| {
        const item: *ZedisListNode = @fieldParentPtr("node", node.?);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "item-{d}", .{i}), switch (item.data) {
            .string => |s| s,
            .short_string => |*ss| ss.as_slice(),
            .int => unreachable,
        });
        node = node.?.next;
    }
}

test "snapshot carries live expiries and drops keys that already expired" {
    var source: TestStore = undefined;
    try source.init();
    defer source.deinit();

    var buf: [24]u8 = undefined;
    const live_at = source.now_ms() + 60_000;
    try source.run(&.{ "SET", "live", "1" });
    try source.run(&.{ "PEXPIREAT", "live", int_text(&buf, live_at) });
    try source.run(&.{ "SET", "stale", "1" });
    try source.run(&.{ "PEXPIREAT", "stale", int_text(&buf, source.now_ms() + 60_000) });

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // A later "now" makes `stale` (and only it) past its deadline.
    try write(&source.store, live_at - 1, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "stale") != null);

    out.clearRetainingCapacity();
    try write(&source.store, live_at + 1, &out.writer);
    try testing.expectEqualStrings("", out.written());

    out.clearRetainingCapacity();
    try dump(&source, &out);
    var copy: TestStore = undefined;
    try copy.init();
    defer copy.deinit();
    try copy.replay(out.written());
    try testing.expectEqual(live_at, copy.store.get_ttl("live").?);
}

test "snapshot recreates a time series with its options and exact sample values" {
    var source: TestStore = undefined;
    try source.init();
    defer source.deinit();

    try source.run(&.{ "TS.CREATE", "temps", "RETENTION", "0", "CHUNK_SIZE", "2", "ENCODING", "UNCOMPRESSED", "DUPLICATE_POLICY", "LAST", "IGNORE", "5", "0.25" });
    const values = [_][]const u8{ "0.1", "-0", "1e300", "5e-324", "123456789.123456789", "inf", "-inf" };
    var buf: [24]u8 = undefined;
    for (values, 0..) |value, i| {
        try source.run(&.{ "TS.ADD", "temps", try std.fmt.bufPrint(&buf, "{d}", .{1000 * (i + 1)}), value });
    }

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump(&source, &out);

    var copy: TestStore = undefined;
    try copy.init();
    defer copy.deinit();
    try copy.replay(out.written());

    const original = (try source.store.get_time_series("temps")).?;
    const restored = (try copy.store.get_time_series("temps")).?;
    try testing.expectEqual(original.retention_ms, restored.retention_ms);
    try testing.expectEqual(original.max_chunk_samples, restored.max_chunk_samples);
    try testing.expectEqual(original.encoding, restored.encoding);
    try testing.expectEqual(original.duplicate_policy, restored.duplicate_policy);
    try testing.expectEqual(original.ignore_max_time_diff, restored.ignore_max_time_diff);
    try testing.expectEqual(original.ignore_max_val_diff, restored.ignore_max_val_diff);

    var before = try original.range("-", "+", null, null);
    defer before.deinit(original.allocator);
    var after = try restored.range("-", "+", null, null);
    defer after.deinit(restored.allocator);
    try testing.expect(before.items.len > 0);
    try testing.expectEqual(before.items.len, after.items.len);
    for (before.items, after.items) |a, b| {
        try testing.expectEqual(a.timestamp, b.timestamp);
        try testing.expectEqual(@as(u64, @bitCast(a.value)), @as(u64, @bitCast(b.value)));
    }
}

test "snapshot refuses datasets holding bloom filters and writes nothing" {
    var source: TestStore = undefined;
    try source.init();
    defer source.deinit();

    try source.run(&.{ "SET", "plain", "x" });
    try source.run(&.{ "BF.RESERVE", "filter", "0.01", "100" });

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.UnsupportedType, dump(&source, &out));
    try testing.expectEqual(@as(usize, 0), out.written().len);
}
