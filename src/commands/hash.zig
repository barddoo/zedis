const std = @import("std");
const store_mod = @import("../storage/store.zig");
const Store = store_mod.Store;
const ZedisHash = @import("../storage/hash.zig").ZedisHash;
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");
const Io = std.Io;
const Writer = Io.Writer;
const testing = std.testing;
const Clock = @import("../app/clock.zig");

/// Write a PrimitiveValue as a RESP bulk string.
fn write_primitive(writer: *Writer, value: PrimitiveValue) !void {
    switch (value) {
        .string => |s| try resp.write_bulk_string(writer, s),
        .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
        .int => |i| try resp.write_int_bulk_string(writer, i),
    }
}

/// HSET key field value [field value ...]
/// Returns the number of new fields added.
pub fn hset(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const pairs = args[2..];
    if (pairs.len == 0 or pairs.len % 2 != 0) return error.WrongNumberOfArguments;

    const h = try store.get_or_create_hash(key);
    var added: usize = 0;
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const field = pairs[i].as_slice();
        const val = try PrimitiveValue.from_slice(pairs[i + 1].as_slice(), store.allocator);
        if (try h.hset(field, val)) added += 1;
    }
    try resp.write_int(writer, added);
}

/// HMSET key field value [field value ...]
/// Deprecated alias for HSET; always returns +OK.
pub fn hmset(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const pairs = args[2..];
    if (pairs.len == 0 or pairs.len % 2 != 0) return error.WrongNumberOfArguments;

    const h = try store.get_or_create_hash(key);
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const field = pairs[i].as_slice();
        const val = try PrimitiveValue.from_slice(pairs[i + 1].as_slice(), store.allocator);
        _ = try h.hset(field, val);
    }
    try resp.write_ok(writer);
}

/// HGET key field
pub fn hget(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const field = args[2].as_slice();

    const h = (try store.get_hash(key)) orelse {
        try resp.write_null(writer);
        return;
    };
    if (h.hget(field)) |value| {
        try write_primitive(writer, value);
    } else {
        try resp.write_null(writer);
    }
}

/// HMGET key field [field ...]
pub fn hmget(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const fields = args[2..];

    const h = try store.get_hash(key);
    try resp.write_list_len(writer, fields.len);
    for (fields) |f| {
        if (h) |hash| {
            if (hash.hget(f.as_slice())) |value| {
                try write_primitive(writer, value);
                continue;
            }
        }
        try resp.write_null(writer);
    }
}

/// HGETALL key
pub fn hgetall(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const h = (try store.get_hash(key)) orelse {
        try resp.write_map_len(writer, 0);
        return;
    };
    try resp.write_map_len(writer, h.hlen());
    var it = h.iterator();
    while (it.next()) |entry| {
        try resp.write_bulk_string(writer, entry.key_ptr.*);
        try write_primitive(writer, entry.value_ptr.*);
    }
}

/// HDEL key field [field ...]
pub fn hdel(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const fields = args[2..];

    const h = (try store.get_hash(key)) orelse {
        try resp.write_int(writer, @as(usize, 0));
        return;
    };
    var deleted: usize = 0;
    for (fields) |f| {
        if (h.hdel(f.as_slice())) deleted += 1;
    }
    try resp.write_int(writer, deleted);
}

/// HEXISTS key field
pub fn hexists(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const field = args[2].as_slice();

    const h = (try store.get_hash(key)) orelse {
        try resp.write_int(writer, @as(u1, 0));
        return;
    };
    try resp.write_int(writer, @as(u1, if (h.hexists(field)) 1 else 0));
}

/// HKEYS key
pub fn hkeys(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const h = (try store.get_hash(key)) orelse {
        try resp.write_list_len(writer, 0);
        return;
    };
    try resp.write_list_len(writer, h.hlen());
    var it = h.iterator();
    while (it.next()) |entry| {
        try resp.write_bulk_string(writer, entry.key_ptr.*);
    }
}

/// HVALS key
pub fn hvals(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const h = (try store.get_hash(key)) orelse {
        try resp.write_list_len(writer, 0);
        return;
    };
    try resp.write_list_len(writer, h.hlen());
    var it = h.iterator();
    while (it.next()) |entry| {
        try write_primitive(writer, entry.value_ptr.*);
    }
}

/// HLEN key
pub fn hlen(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const h = (try store.get_hash(key)) orelse {
        try resp.write_int(writer, @as(usize, 0));
        return;
    };
    try resp.write_int(writer, h.hlen());
}

// --- Tests ---

fn make_store(allocator: std.mem.Allocator) !Store {
    var clock = Clock.init(testing.io, 0);
    return Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 64 });
}

test "HSET creates fields and returns new-field count" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    const args = [_]Value{
        .{ .data = "HSET" }, .{ .data = "h" },
        .{ .data = "f1" },   .{ .data = "v1" },
        .{ .data = "f2" },   .{ .data = "v2" },
    };
    try hset(&writer, &store, &args);
    try testing.expectEqualStrings(":2\r\n", writer.buffered());

    // Update f1 — only 0 new fields.
    writer = Writer.fixed(&buf);
    const args2 = [_]Value{
        .{ .data = "HSET" }, .{ .data = "h" },
        .{ .data = "f1" },   .{ .data = "new" },
    };
    try hset(&writer, &store, &args2);
    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "HGET returns value or null" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    _ = try store.get_or_create_hash("h");
    const h = (try store.get_hash("h")).?;
    _ = try h.hset("field", try PrimitiveValue.from_slice("hello", testing.allocator));

    try hget(&writer, &store, &[_]Value{ .{ .data = "HGET" }, .{ .data = "h" }, .{ .data = "field" } });
    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());

    writer = Writer.fixed(&buf);
    try hget(&writer, &store, &[_]Value{ .{ .data = "HGET" }, .{ .data = "h" }, .{ .data = "missing" } });
    try testing.expectEqualStrings("$-1\r\n", writer.buffered());

    writer = Writer.fixed(&buf);
    try hget(&writer, &store, &[_]Value{ .{ .data = "HGET" }, .{ .data = "nosuchkey" }, .{ .data = "f" } });
    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "HMSET sets multiple fields and returns OK" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hmset(&writer, &store, &[_]Value{
        .{ .data = "HMSET" }, .{ .data = "h" },
        .{ .data = "a" },     .{ .data = "1" },
        .{ .data = "b" },     .{ .data = "2" },
    });
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const h = (try store.get_hash("h")).?;
    try testing.expectEqual(@as(usize, 2), h.hlen());
}

test "HMGET returns array with nulls for missing fields" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hset(&writer, &store, &[_]Value{
        .{ .data = "HSET" }, .{ .data = "h" },
        .{ .data = "x" },    .{ .data = "10" },
    });

    writer = Writer.fixed(&buf);
    try hmget(&writer, &store, &[_]Value{
        .{ .data = "HMGET" }, .{ .data = "h" },
        .{ .data = "x" },     .{ .data = "y" },
    });
    try testing.expectEqualStrings("*2\r\n$2\r\n10\r\n$-1\r\n", writer.buffered());
}

test "HGETALL returns all fields and values" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [512]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hset(&writer, &store, &[_]Value{
        .{ .data = "HSET" }, .{ .data = "h" },
        .{ .data = "k" },    .{ .data = "v" },
    });
    writer = Writer.fixed(&buf);
    try hgetall(&writer, &store, &[_]Value{ .{ .data = "HGETALL" }, .{ .data = "h" } });
    try testing.expectEqualStrings("*2\r\n$1\r\nk\r\n$1\r\nv\r\n", writer.buffered());

    // Missing key returns empty array.
    writer = Writer.fixed(&buf);
    try hgetall(&writer, &store, &[_]Value{ .{ .data = "HGETALL" }, .{ .data = "nosuchkey" } });
    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "HDEL deletes fields and returns count" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hset(&writer, &store, &[_]Value{
        .{ .data = "HSET" }, .{ .data = "h" },
        .{ .data = "a" },    .{ .data = "1" },
        .{ .data = "b" },    .{ .data = "2" },
    });
    writer = Writer.fixed(&buf);
    try hdel(&writer, &store, &[_]Value{
        .{ .data = "HDEL" }, .{ .data = "h" },
        .{ .data = "a" },    .{ .data = "nosuch" },
    });
    try testing.expectEqualStrings(":1\r\n", writer.buffered());
    try testing.expectEqual(@as(usize, 1), (try store.get_hash("h")).?.hlen());
}

test "HEXISTS returns 1 or 0" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [64]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hset(&writer, &store, &[_]Value{
        .{ .data = "HSET" }, .{ .data = "h" }, .{ .data = "f" }, .{ .data = "v" },
    });
    writer = Writer.fixed(&buf);
    try hexists(&writer, &store, &[_]Value{ .{ .data = "HEXISTS" }, .{ .data = "h" }, .{ .data = "f" } });
    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    writer = Writer.fixed(&buf);
    try hexists(&writer, &store, &[_]Value{ .{ .data = "HEXISTS" }, .{ .data = "h" }, .{ .data = "missing" } });
    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "HKEYS and HVALS return field names and values" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [256]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hset(&writer, &store, &[_]Value{
        .{ .data = "HSET" }, .{ .data = "h" }, .{ .data = "k" }, .{ .data = "v" },
    });
    writer = Writer.fixed(&buf);
    try hkeys(&writer, &store, &[_]Value{ .{ .data = "HKEYS" }, .{ .data = "h" } });
    try testing.expectEqualStrings("*1\r\n$1\r\nk\r\n", writer.buffered());

    writer = Writer.fixed(&buf);
    try hvals(&writer, &store, &[_]Value{ .{ .data = "HVALS" }, .{ .data = "h" } });
    try testing.expectEqualStrings("*1\r\n$1\r\nv\r\n", writer.buffered());
}

test "HLEN returns field count" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    var buf: [64]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try hlen(&writer, &store, &[_]Value{ .{ .data = "HLEN" }, .{ .data = "nosuchkey" } });
    try testing.expectEqualStrings(":0\r\n", writer.buffered());

    try hset(&writer, &store, &[_]Value{
        .{ .data = "HSET" }, .{ .data = "h" },
        .{ .data = "a" },    .{ .data = "1" },
        .{ .data = "b" },    .{ .data = "2" },
        .{ .data = "c" },    .{ .data = "3" },
    });
    writer = Writer.fixed(&buf);
    try hlen(&writer, &store, &[_]Value{ .{ .data = "HLEN" }, .{ .data = "h" } });
    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "hash commands return WRONGTYPE on non-hash key" {
    var store = try make_store(testing.allocator);
    defer store.deinit();
    try store.set("str", "value");

    var buf: [64]u8 = undefined;
    var writer = Writer.fixed(&buf);

    try testing.expectError(error.WrongType, hget(&writer, &store, &[_]Value{
        .{ .data = "HGET" }, .{ .data = "str" }, .{ .data = "f" },
    }));
}
