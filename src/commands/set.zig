const std = @import("std");
const Store = @import("../storage/store.zig").Store;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");
const string_match = @import("../util/string_match.zig").string_match;
const Io = std.Io;
const Writer = Io.Writer;
const testing = std.testing;
const Clock = @import("../app/clock.zig");

/// SADD key member [member ...]
pub fn sadd(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const set = try store.get_or_create_set(key);
    // A failed first allocation must not leave an empty set behind.
    errdefer if (set.len() == 0) {
        _ = store.delete(key);
    };

    var added: usize = 0;
    for (args[2..]) |member| {
        if (try set.add(member.as_slice())) added += 1;
    }
    try resp.write_int(writer, added);
}

/// SREM key member [member ...]
pub fn srem(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const set = try store.get_set(key) orelse {
        try resp.write_int(writer, 0);
        return;
    };

    var removed: usize = 0;
    for (args[2..]) |member| {
        if (set.remove(member.as_slice())) removed += 1;
    }
    if (set.len() == 0) _ = store.delete(key);
    try resp.write_int(writer, removed);
}

/// SMEMBERS key
pub fn smembers(writer: *Writer, store: *Store, args: []const Value) !void {
    const set = try store.get_set(args[1].as_slice()) orelse {
        try resp.write_set_len(writer, 0);
        return;
    };

    // Preflight the deadline before writing any RESP bytes: aborting after the
    // length header would leave a partial reply on the wire.
    var probe = set.iterator();
    var index: usize = 0;
    while (probe.next() != null) : (index += 1) {
        if (index % 1024 == 0 and store.commandExpired()) return error.CommandTimeout;
    }

    try resp.write_set_len(writer, set.len());
    var it = set.iterator();
    while (it.next()) |member| try resp.write_bulk_string(writer, member.*);
}

/// SCARD key
pub fn scard(writer: *Writer, store: *Store, args: []const Value) !void {
    const set = try store.get_set(args[1].as_slice()) orelse {
        try resp.write_int(writer, 0);
        return;
    };
    try resp.write_int(writer, set.len());
}

/// SISMEMBER key member
pub fn sismember(writer: *Writer, store: *Store, args: []const Value) !void {
    const set = try store.get_set(args[1].as_slice()) orelse {
        try resp.write_int(writer, 0);
        return;
    };
    try resp.write_int(writer, @intFromBool(set.contains(args[2].as_slice())));
}

/// SSCAN key cursor [MATCH pattern] [COUNT count]
/// Cursor-based iteration over set members. Zedis uses a flat hash map with no
/// stable slot numbering, so we always do a full scan and return cursor 0 —
/// this matches Redis's guarantee that cursor 0 signals "done".
pub fn sscan(writer: *Writer, store: *Store, args: []const Value) !void {
    // args: [0]=SSCAN [1]=key [2]=cursor [3..]=options
    const key = args[1].as_slice();
    _ = args[2].as_u64() catch return resp.write_error(writer, "ERR invalid cursor");

    var pattern: []const u8 = "*";
    var i: usize = 3;
    while (i < args.len) {
        const opt = args[i].as_slice();
        if (std.ascii.eqlIgnoreCase(opt, "MATCH") and i + 1 < args.len) {
            pattern = args[i + 1].as_slice();
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(opt, "COUNT") and i + 1 < args.len) {
            _ = args[i + 1].as_usize() catch return error.SyntaxError;
            i += 2;
        } else {
            return error.SyntaxError;
        }
    }

    const set = try store.get_set(key);

    try resp.write_list_len(writer, 2);
    try resp.write_bulk_string(writer, "0"); // always done in one pass

    if (set) |s| {
        var count: usize = 0;
        var it = s.iterator();
        while (it.next()) |member| {
            if (string_match(pattern, member.*)) count += 1;
        }
        try resp.write_list_len(writer, count);
        it = s.iterator();
        while (it.next()) |member| {
            if (string_match(pattern, member.*)) try resp.write_bulk_string(writer, member.*);
        }
    } else {
        try resp.write_list_len(writer, 0);
    }
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

test "SADD counts only new members and SCARD reflects them" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [256]u8 = undefined;

    const out = try run(store, &buf, sadd, &.{ .{ .data = "SADD" }, .{ .data = "s" }, .{ .data = "a" }, .{ .data = "b" }, .{ .data = "a" } });
    try testing.expectEqualStrings(":2\r\n", out);
    try testing.expectEqualStrings(":2\r\n", try run(store, &buf, scard, &.{ .{ .data = "SCARD" }, .{ .data = "s" } }));
    try testing.expectEqualStrings(":0\r\n", try run(store, &buf, scard, &.{ .{ .data = "SCARD" }, .{ .data = "none" } }));
}

test "SISMEMBER distinguishes present and absent members" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [256]u8 = undefined;
    _ = try run(store, &buf, sadd, &.{ .{ .data = "SADD" }, .{ .data = "s" }, .{ .data = "a" } });

    try testing.expectEqualStrings(":1\r\n", try run(store, &buf, sismember, &.{ .{ .data = "SISMEMBER" }, .{ .data = "s" }, .{ .data = "a" } }));
    try testing.expectEqualStrings(":0\r\n", try run(store, &buf, sismember, &.{ .{ .data = "SISMEMBER" }, .{ .data = "s" }, .{ .data = "z" } }));
}

test "SREM deletes the key once the set is empty" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [256]u8 = undefined;
    _ = try run(store, &buf, sadd, &.{ .{ .data = "SADD" }, .{ .data = "s" }, .{ .data = "a" }, .{ .data = "b" } });

    try testing.expectEqualStrings(":2\r\n", try run(store, &buf, srem, &.{ .{ .data = "SREM" }, .{ .data = "s" }, .{ .data = "a" }, .{ .data = "b" }, .{ .data = "x" } }));
    try testing.expect(try store.get_set("s") == null);
}

test "SMEMBERS lists every member" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [256]u8 = undefined;
    _ = try run(store, &buf, sadd, &.{ .{ .data = "SADD" }, .{ .data = "s" }, .{ .data = "only" } });

    try testing.expectEqualStrings("*1\r\n$4\r\nonly\r\n", try run(store, &buf, smembers, &.{ .{ .data = "SMEMBERS" }, .{ .data = "s" } }));
    try testing.expectEqualStrings("*0\r\n", try run(store, &buf, smembers, &.{ .{ .data = "SMEMBERS" }, .{ .data = "none" } }));
}

test "SSCAN returns cursor 0 and all members, with MATCH filtering" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [512]u8 = undefined;

    _ = try run(store, &buf, sadd, &.{ .{ .data = "SADD" }, .{ .data = "s" }, .{ .data = "aa" }, .{ .data = "bb" }, .{ .data = "cc" } });

    const out = try run(store, &buf, sscan, &.{ .{ .data = "SSCAN" }, .{ .data = "s" }, .{ .data = "0" } });
    try testing.expect(std.mem.startsWith(u8, out, "*2\r\n$1\r\n0\r\n*3\r\n"));

    const filtered = try run(store, &buf, sscan, &.{
        .{ .data = "SSCAN" }, .{ .data = "s" },  .{ .data = "0" },
        .{ .data = "MATCH" }, .{ .data = "a*" },
    });
    try testing.expectEqualStrings("*2\r\n$1\r\n0\r\n*1\r\n$2\r\naa\r\n", filtered);

    const empty = try run(store, &buf, sscan, &.{ .{ .data = "SSCAN" }, .{ .data = "nosuchkey" }, .{ .data = "0" } });
    try testing.expectEqualStrings("*2\r\n$1\r\n0\r\n*0\r\n", empty);
}

test "set commands reject keys holding another type" {
    var env: Env = undefined;
    try env.init();
    defer env.store.deinit();
    const store = &env.store;
    var buf: [256]u8 = undefined;
    try store.set("str", "text");

    try testing.expectError(error.WrongType, run(store, &buf, sadd, &.{ .{ .data = "SADD" }, .{ .data = "str" }, .{ .data = "a" } }));
    try testing.expectError(error.WrongType, run(store, &buf, smembers, &.{ .{ .data = "SMEMBERS" }, .{ .data = "str" } }));
}
