const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const ZedisZSet = @import("../storage/zset.zig").ZedisZSet;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");
const Io = std.Io;
const Writer = Io.Writer;
const testing = std.testing;
const Clock = @import("../app/clock.zig");

fn parse_score(arg: Value) !f64 {
    const score = arg.as_f64() catch return error.InvalidFloat;
    if (std.math.isNan(score)) return error.InvalidFloat;
    return score;
}

fn parse_int(arg: Value) !i64 {
    return arg.as_int() catch error.ValueNotInteger;
}

const Bound = struct { value: f64, exclusive: bool };

/// Parses a score range endpoint: `1.5`, `(1.5` (exclusive), `-inf`, `+inf`.
fn parse_bound(arg: Value) !Bound {
    const text = arg.as_slice();
    const exclusive = text.len > 0 and text[0] == '(';
    const number = if (exclusive) text[1..] else text;
    const value = std.fmt.parseFloat(f64, number) catch return error.InvalidRange;
    if (std.math.isNan(value)) return error.InvalidRange;
    return .{ .value = value, .exclusive = exclusive };
}

/// ZADD key [NX|XX] [GT|LT] [CH] score member [score member ...]
pub fn zadd(writer: *Writer, store: *Store, args: []const Value) !void {
    var nx = false;
    var xx = false;
    var gt = false;
    var lt = false;
    var ch = false;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const opt = args[i].as_slice();
        if (std.ascii.eqlIgnoreCase(opt, "NX")) nx = true else if (std.ascii.eqlIgnoreCase(opt, "XX")) xx = true else if (std.ascii.eqlIgnoreCase(opt, "GT")) gt = true else if (std.ascii.eqlIgnoreCase(opt, "LT")) lt = true else if (std.ascii.eqlIgnoreCase(opt, "CH")) ch = true else break;
    }
    const pairs = args[i..];
    if (pairs.len == 0 or pairs.len % 2 != 0) return error.SyntaxError;
    if ((nx and xx) or (gt and lt) or (nx and (gt or lt))) return error.SyntaxError;

    // Validate every score first so a bad one cannot leave a partial update.
    var p: usize = 0;
    while (p < pairs.len) : (p += 2) _ = try parse_score(pairs[p]);

    const key = args[1].as_slice();
    const z = try store.get_or_create_zset(key);
    errdefer if (z.len() == 0) {
        _ = store.delete(key);
    };

    var changed: usize = 0;
    p = 0;
    while (p < pairs.len) : (p += 2) {
        const score = try parse_score(pairs[p]);
        const member = pairs[p + 1].as_slice();
        const existing = z.score(member);

        if (existing != null and nx) continue;
        if (existing == null and xx) continue;
        if (existing) |old| {
            if (gt and score <= old) continue;
            if (lt and score >= old) continue;
        }

        switch (try z.add(member, score)) {
            .added => changed += 1,
            .updated => if (ch) {
                changed += 1;
            },
            .unchanged => {},
        }
    }
    try resp.write_int(writer, changed);
}

/// ZINCRBY key increment member
pub fn zincrby(writer: *Writer, store: *Store, args: []const Value) !void {
    const increment = try parse_score(args[2]);
    const member = args[3].as_slice();
    const key = args[1].as_slice();

    const z = try store.get_or_create_zset(key);
    errdefer if (z.len() == 0) {
        _ = store.delete(key);
    };

    const next = (z.score(member) orelse 0) + increment;
    if (std.math.isNan(next)) return error.ScoreNaN;
    _ = try z.add(member, next);
    try resp.write_double_bulk_string(writer, next);
}

/// ZREM key member [member ...]
pub fn zrem(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const z = try store.get_zset(key) orelse {
        try resp.write_int(writer, 0);
        return;
    };

    var removed: usize = 0;
    for (args[2..]) |member| {
        if (z.remove(member.as_slice())) removed += 1;
    }
    if (z.len() == 0) _ = store.delete(key);
    try resp.write_int(writer, removed);
}

/// ZCARD key
pub fn zcard(writer: *Writer, store: *Store, args: []const Value) !void {
    const z = try store.get_zset(args[1].as_slice()) orelse {
        try resp.write_int(writer, 0);
        return;
    };
    try resp.write_int(writer, z.len());
}

/// ZSCORE key member
pub fn zscore(writer: *Writer, store: *Store, args: []const Value) !void {
    const z = try store.get_zset(args[1].as_slice()) orelse return resp.write_null(writer);
    const score = z.score(args[2].as_slice()) orelse return resp.write_null(writer);
    try resp.write_double_bulk_string(writer, score);
}

/// ZREMRANGEBYSCORE key min max
pub fn zremrangebyscore(writer: *Writer, store: *Store, args: []const Value) !void {
    const min = try parse_bound(args[2]);
    const max = try parse_bound(args[3]);
    const key = args[1].as_slice();
    const z = try store.get_zset(key) orelse {
        try resp.write_int(writer, 0);
        return;
    };

    const start = z.first_index_from(min.value, min.exclusive);
    const end = z.end_index_to(max.value, max.exclusive);
    const removed = if (start < end) z.remove_range(start, end) else 0;
    if (z.len() == 0) _ = store.delete(key);
    try resp.write_int(writer, removed);
}

const Selection = struct {
    /// First and one-past-last forward indices of the selected entries.
    start: usize,
    end: usize,
    reverse: bool,
    skip: usize = 0,
    limit: usize = std.math.maxInt(usize),
};

fn write_selection(writer: *Writer, z: ?*const ZedisZSet, sel: Selection, with_scores: bool) !void {
    const zs = z orelse return resp.write_list_len(writer, 0);
    if (sel.start >= sel.end) return resp.write_list_len(writer, 0);

    const available = sel.end - sel.start;
    const skip = @min(sel.skip, available);
    const count = @min(sel.limit, available - skip);
    try resp.write_list_len(writer, if (with_scores) count * 2 else count);

    for (0..count) |n| {
        const idx = if (sel.reverse) sel.end - 1 - skip - n else sel.start + skip + n;
        const entry = zs.order.items[idx];
        try resp.write_bulk_string(writer, entry.member);
        if (with_scores) try resp.write_double_bulk_string(writer, entry.score);
    }
}

/// Resolves an inclusive rank range, negative indices counting from the end,
/// into forward indices. `reverse` ranks from the highest score.
fn rank_selection(len: usize, first: i64, last: i64, reverse: bool) Selection {
    const n: i64 = @intCast(len);
    var s = if (first < 0) first + n else first;
    var e = if (last < 0) last + n else last;
    if (s < 0) s = 0;
    if (e >= n) e = n - 1;
    if (s > e or s >= n) return .{ .start = 0, .end = 0, .reverse = reverse };

    const su: usize = @intCast(s);
    const eu: usize = @intCast(e);
    if (reverse) return .{ .start = len - 1 - eu, .end = len - su, .reverse = true };
    return .{ .start = su, .end = eu + 1, .reverse = false };
}

const Options = struct {
    with_scores: bool = false,
    by_score: bool = false,
    reverse: bool = false,
    offset: i64 = 0,
    count: i64 = -1,
    has_limit: bool = false,
};

fn parse_options(opts: []const Value, allow_byscore: bool, allow_rev: bool) !Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        const opt = opts[i].as_slice();
        if (std.ascii.eqlIgnoreCase(opt, "WITHSCORES")) {
            o.with_scores = true;
        } else if (allow_byscore and std.ascii.eqlIgnoreCase(opt, "BYSCORE")) {
            o.by_score = true;
        } else if (allow_rev and std.ascii.eqlIgnoreCase(opt, "REV")) {
            o.reverse = true;
        } else if (std.ascii.eqlIgnoreCase(opt, "LIMIT") and i + 2 < opts.len) {
            o.offset = try parse_int(opts[i + 1]);
            o.count = try parse_int(opts[i + 2]);
            o.has_limit = true;
            i += 2;
        } else {
            return error.SyntaxError;
        }
    }
    return o;
}

fn score_selection(z: *const ZedisZSet, lo: Value, hi: Value, o: Options) !Selection {
    // REV takes the endpoints as max then min.
    const min = try parse_bound(if (o.reverse) hi else lo);
    const max = try parse_bound(if (o.reverse) lo else hi);
    var sel: Selection = .{
        .start = z.first_index_from(min.value, min.exclusive),
        .end = z.end_index_to(max.value, max.exclusive),
        .reverse = o.reverse,
    };
    if (o.has_limit) {
        // A negative offset selects nothing, as in Redis.
        if (o.offset < 0) return .{ .start = 0, .end = 0, .reverse = o.reverse };
        sel.skip = @intCast(o.offset);
        if (o.count >= 0) sel.limit = @intCast(o.count);
    }
    return sel;
}

fn range_reply(writer: *Writer, store: *Store, args: []const Value, o: Options) !void {
    const z = try store.get_zset(args[1].as_slice());
    if (o.has_limit and !o.by_score) return error.SyntaxError;

    if (o.by_score) {
        const sel = if (z) |zs| try score_selection(zs, args[2], args[3], o) else Selection{ .start = 0, .end = 0, .reverse = false };
        return write_selection(writer, z, sel, o.with_scores);
    }

    const first = try parse_int(args[2]);
    const last = try parse_int(args[3]);
    const len = if (z) |zs| zs.len() else 0;
    return write_selection(writer, z, rank_selection(len, first, last, o.reverse), o.with_scores);
}

/// ZRANGE key start stop [BYSCORE] [REV] [LIMIT offset count] [WITHSCORES]
pub fn zrange(writer: *Writer, store: *Store, args: []const Value) !void {
    try range_reply(writer, store, args, try parse_options(args[4..], true, true));
}

/// ZREVRANGE key start stop [WITHSCORES]
pub fn zrevrange(writer: *Writer, store: *Store, args: []const Value) !void {
    var o = try parse_options(args[4..], false, false);
    o.reverse = true;
    try range_reply(writer, store, args, o);
}

/// ZRANGEBYSCORE key min max [WITHSCORES] [LIMIT offset count]
pub fn zrangebyscore(writer: *Writer, store: *Store, args: []const Value) !void {
    var o = try parse_options(args[4..], false, false);
    o.by_score = true;
    try range_reply(writer, store, args, o);
}

/// ZREVRANGEBYSCORE key max min [WITHSCORES] [LIMIT offset count]
pub fn zrevrangebyscore(writer: *Writer, store: *Store, args: []const Value) !void {
    var o = try parse_options(args[4..], false, false);
    o.by_score = true;
    o.reverse = true;
    try range_reply(writer, store, args, o);
}

/// Owns the clock the store points at, so it outlives every store call.
const Env = struct {
    clock: Clock,
    store: Store,

    fn init(self: *Env) !void {
        self.clock = Clock.init(testing.io, 0);
        self.store = try Store.init(testing.allocator, testing.io, &self.clock, .{ .initial_capacity = 64 });
    }
};

fn run(store: *Store, buf: []u8, handler: anytype, args: []const Value) ![]const u8 {
    var writer = Writer.fixed(buf);
    try handler(&writer, store, args);
    return writer.buffered();
}

fn v(comptime text: []const u8) Value {
    return .{ .data = text };
}

fn seed(store: *Store) !void {
    var buf: [64]u8 = undefined;
    _ = try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("1"), v("a"), v("2"), v("b"), v("3"), v("c") });
}

test "ZADD counts new members and CH also counts score changes" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings(":2\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("1"), v("a"), v("2"), v("b") }));
    try testing.expectEqualStrings(":0\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("5"), v("a") }));
    try testing.expectEqualStrings(":1\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("CH"), v("6"), v("a") }));
}

test "ZADD NX XX GT LT gate updates" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [64]u8 = undefined;
    try seed(store);

    try testing.expectEqualStrings(":0\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("NX"), v("CH"), v("9"), v("a") }));
    try testing.expectEqualStrings(":0\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("XX"), v("9"), v("new") }));
    try testing.expectEqualStrings(":0\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("GT"), v("CH"), v("0"), v("a") }));
    try testing.expectEqualStrings(":1\r\n", try run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("LT"), v("CH"), v("0"), v("a") }));
    try testing.expectError(error.SyntaxError, run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("NX"), v("XX"), v("1"), v("a") }));
}

test "ZADD rejects a bad score without applying earlier pairs" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [64]u8 = undefined;

    try testing.expectError(error.InvalidFloat, run(store, &buf, zadd, &.{ v("ZADD"), v("z"), v("1"), v("a"), v("nope"), v("b") }));
    try testing.expect(try store.get_zset("z") == null);
}

test "ZRANGE by rank handles negatives, REV and WITHSCORES" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [128]u8 = undefined;
    try seed(store);

    try testing.expectEqualStrings("*2\r\n$1\r\nb\r\n$1\r\nc\r\n", try run(store, &buf, zrange, &.{ v("ZRANGE"), v("z"), v("-2"), v("-1") }));
    try testing.expectEqualStrings("*2\r\n$1\r\nc\r\n$1\r\nb\r\n", try run(store, &buf, zrange, &.{ v("ZRANGE"), v("z"), v("0"), v("1"), v("REV") }));
    try testing.expectEqualStrings("*2\r\n$1\r\na\r\n$1\r\n1\r\n", try run(store, &buf, zrange, &.{ v("ZRANGE"), v("z"), v("0"), v("0"), v("WITHSCORES") }));
    try testing.expectEqualStrings("*0\r\n", try run(store, &buf, zrange, &.{ v("ZRANGE"), v("z"), v("5"), v("9") }));
    try testing.expectEqualStrings("*0\r\n", try run(store, &buf, zrange, &.{ v("ZRANGE"), v("none"), v("0"), v("-1") }));
}

test "ZRANGE BYSCORE and ZRANGEBYSCORE apply bounds and LIMIT" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [128]u8 = undefined;
    try seed(store);

    try testing.expectEqualStrings("*2\r\n$1\r\nb\r\n$1\r\nc\r\n", try run(store, &buf, zrangebyscore, &.{ v("ZRANGEBYSCORE"), v("z"), v("(1"), v("+inf") }));
    try testing.expectEqualStrings("*1\r\n$1\r\nb\r\n", try run(store, &buf, zrangebyscore, &.{ v("ZRANGEBYSCORE"), v("z"), v("-inf"), v("+inf"), v("LIMIT"), v("1"), v("1") }));
    try testing.expectEqualStrings("*1\r\n$1\r\nc\r\n", try run(store, &buf, zrange, &.{ v("ZRANGE"), v("z"), v("+inf"), v("-inf"), v("BYSCORE"), v("REV"), v("LIMIT"), v("0"), v("1") }));
    try testing.expectError(error.InvalidRange, run(store, &buf, zrangebyscore, &.{ v("ZRANGEBYSCORE"), v("z"), v("x"), v("1") }));
    try testing.expectError(error.SyntaxError, run(store, &buf, zrange, &.{ v("ZRANGE"), v("z"), v("0"), v("1"), v("LIMIT"), v("0"), v("1") }));
}

test "ZREM and ZREMRANGEBYSCORE delete the key once empty" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [64]u8 = undefined;
    try seed(store);

    try testing.expectEqualStrings(":1\r\n", try run(store, &buf, zrem, &.{ v("ZREM"), v("z"), v("a"), v("missing") }));
    try testing.expectEqualStrings(":2\r\n", try run(store, &buf, zremrangebyscore, &.{ v("ZREMRANGEBYSCORE"), v("z"), v("-inf"), v("+inf") }));
    try testing.expect(try store.get_zset("z") == null);
}

test "ZINCRBY creates members and ZSCORE reads them back" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("$3\r\n1.5\r\n", try run(store, &buf, zincrby, &.{ v("ZINCRBY"), v("z"), v("1.5"), v("m") }));
    try testing.expectEqualStrings("$1\r\n3\r\n", try run(store, &buf, zincrby, &.{ v("ZINCRBY"), v("z"), v("1.5"), v("m") }));
    try testing.expectEqualStrings("$1\r\n3\r\n", try run(store, &buf, zscore, &.{ v("ZSCORE"), v("z"), v("m") }));
    try testing.expectEqualStrings("$-1\r\n", try run(store, &buf, zscore, &.{ v("ZSCORE"), v("z"), v("nobody") }));
    try testing.expectEqualStrings(":1\r\n", try run(store, &buf, zcard, &.{ v("ZCARD"), v("z") }));
}

test "zset commands reject keys holding another type" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [64]u8 = undefined;
    try store.set("str", "text");

    try testing.expectError(error.WrongType, run(store, &buf, zadd, &.{ v("ZADD"), v("str"), v("1"), v("a") }));
    try testing.expectError(error.WrongType, run(store, &buf, zcard, &.{ v("ZCARD"), v("str") }));
}
