const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const Io = std.Io;
const Writer = Io.Writer;
const Clock = @import("../clock.zig");
const PrimitiveValue = @import("../types.zig").PrimitiveValue;
const testing = std.testing;
const mem = std.mem;

pub fn keys(writer: *Writer, store: *Store, args: []const Value) !void {
    const pattern = args[1].asSlice();

    const all_keys = try store.keys(store.allocator, pattern);
    defer store.allocator.free(all_keys);
    try resp.writeListLen(writer, all_keys.len);
    for (all_keys) |key| {
        try resp.writeBulkString(writer, key);
    }
}

pub fn exists(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    if (store.exists(key)) {
        try resp.writeInt(writer, 1);
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn ttl(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const exists_key = store.exists(key);

    if (!exists_key) {
        try resp.writeInt(writer, -2);
        return;
    }
    const ttl_int = store.getTtl(key) orelse -1;
    try resp.writeInt(writer, ttl_int);
}

pub fn persist(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const result = store.persist(key);
    if (result) {
        try resp.writeInt(writer, 1);
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn typeCmd(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const obj = store.get(key);

    const type_str = if (obj) |o| switch (o.value) {
        .string, .short_string, .int => "string",
        .list => "list",
        .time_series => "tseries-type",
        .bloom_filter => "bloom_filter",
    } else "none";

    try resp.writeBulkString(writer, type_str);
}

pub fn rename(writer: *Writer, store: *Store, args: []const Value) !void {
    const old_key = args[1].asSlice();
    const new_key = args[2].asSlice();

    const renamed = try store.renameKey(old_key, new_key);
    if (!renamed) {
        return error.KeyNotFound;
    }

    try resp.writeSimpleString(writer, "OK");
}

pub fn randomkey(writer: *Writer, store: *Store, _: []const Value) !void {
    var random = std.Random.DefaultPrng.init(@intCast(0));
    const key = store.randomKey(random.random());

    if (key) |k| {
        try resp.writeBulkString(writer, k);
    } else {
        try resp.writeNull(writer);
    }
}

test "EXISTS command with existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const args = [_]Value{
        .{ .data = "EXISTS" },
        .{ .data = "mykey" },
    };

    try exists(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());
}

test "EXISTS command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "EXISTS" },
        .{ .data = "nonexistent" },
    };

    try exists(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "TTL command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "TTL" },
        .{ .data = "nonexistent" },
    };

    try ttl(&writer, &store, &args);

    try testing.expectEqualStrings(":-2\r\n", writer.buffered());
}

test "TTL command with key without expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const args = [_]Value{
        .{ .data = "TTL" },
        .{ .data = "mykey" },
    };

    try ttl(&writer, &store, &args);

    try testing.expectEqualStrings(":-1\r\n", writer.buffered());
}

test "TTL command with key with expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "value");
    const now = Io.Clock.real.now(testing.io);
    const future_time = now.toMilliseconds() + 10000;
    _ = try store.expire("mykey", future_time);

    const args = [_]Value{
        .{ .data = "TTL" },
        .{ .data = "mykey" },
    };

    try ttl(&writer, &store, &args);

    const output = writer.buffered();
    // Should return the expiration timestamp
    try testing.expect(mem.startsWith(u8, output, ":"));
}

test "PERSIST command with key having expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const now = Io.Clock.real.now(testing.io);
    const future_time = now.toMilliseconds() + 10000;
    _ = try store.expire("mykey", future_time);

    const args = [_]Value{
        .{ .data = "PERSIST" },
        .{ .data = "mykey" },
    };

    try persist(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    // Verify expiration was removed
    const ttl_val = store.getTtl("mykey");
    try testing.expect(ttl_val == null);
}

test "PERSIST command with key without expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const args = [_]Value{
        .{ .data = "PERSIST" },
        .{ .data = "mykey" },
    };

    try persist(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "TYPE command with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "hello");

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mykey" },
    };

    try typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$6\r\nstring\r\n", writer.buffered());
}

test "TYPE command with integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.setInt("mykey", 42);

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mykey" },
    };

    try typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$6\r\nstring\r\n", writer.buffered());
}

test "TYPE command with list value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    _ = try store.createList("mylist");

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mylist" },
    };

    try typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$4\r\nlist\r\n", writer.buffered());
}

test "TYPE command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "nonexistent" },
    };

    try typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$4\r\nnone\r\n", writer.buffered());
}

test "RENAME command with existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("oldkey", "value");

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "oldkey" },
        .{ .data = "newkey" },
    };

    try rename(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    // Verify old key is gone
    try testing.expect(store.get("oldkey") == null);

    // Verify new key exists with same value
    const new_value = store.get("newkey");
    try testing.expect(new_value != null);
    try testing.expectEqualStrings("value", new_value.?.value.short_string.asSlice());
}

test "RENAME command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "nonexistent" },
        .{ .data = "newkey" },
    };

    const result = rename(&writer, &store, &args);
    try testing.expectError(error.KeyNotFound, result);
}

test "RANDOMKEY command with non-empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("key3", "value3");

    const args = [_]Value{
        .{ .data = "RANDOMKEY" },
    };

    try randomkey(&writer, &store, &args);

    const output = writer.buffered();
    // Should return a bulk string (key)
    try testing.expect(mem.startsWith(u8, output, "$"));
    // Should not be null
    try testing.expect(!mem.eql(u8, output, "$-1\r\n"));
}

test "RANDOMKEY command with empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RANDOMKEY" },
    };

    try randomkey(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "KEYS command returns all keys when pattern is wildcard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("apple", "fruit");
    try store.set("banana", "fruit");
    try store.setInt("count", 42);

    const args = [_]Value{
        .{ .data = "KEYS" },
        .{ .data = "*" },
    };

    try keys(&writer, &store, &args);

    const output = writer.buffered();
    // Should return array with 3 elements
    try testing.expect(mem.startsWith(u8, output, "*3\r\n"));
    // Verify all keys are present in output
    try testing.expect(mem.indexOf(u8, output, "apple") != null);
    try testing.expect(mem.indexOf(u8, output, "banana") != null);
    try testing.expect(mem.indexOf(u8, output, "count") != null);
}

test "RENAME overwrites existing destination key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("source", "source_value");
    try store.set("dest", "dest_value");

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "source" },
        .{ .data = "dest" },
    };

    try rename(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    // Verify source is gone
    try testing.expect(store.get("source") == null);

    // Verify dest has source's value
    const dest_value = store.get("dest");
    try testing.expect(dest_value != null);
    try testing.expectEqualStrings("source_value", dest_value.?.value.short_string.asSlice());
}

test "RENAME preserves list ownership" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const list = try store.createList("source");
    try list.append(PrimitiveValue{ .int = 42 });

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "source" },
        .{ .data = "dest" },
    };

    try rename(&writer, &store, &args);

    try testing.expect(store.get("source") == null);

    const renamed_list = (try store.getList("dest")).?;
    try testing.expectEqual(@as(usize, 1), renamed_list.len());

    const item = renamed_list.pop().?;
    switch (item) {
        .int => |value| try testing.expectEqual(@as(i64, 42), value),
        else => return error.TestUnexpectedResult,
    }
}
