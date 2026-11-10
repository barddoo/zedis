const std = @import("std");
const storeModule = @import("../storage/store.zig");
const Store = storeModule.Store;
const ValueType = storeModule.ValueType;
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");
const string_match = @import("../util/string_match.zig").string_match;
const Io = std.Io;
const Writer = Io.Writer;
const Clock = @import("../app/clock.zig");
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;
const testing = std.testing;
const mem = std.mem;

pub fn keys(writer: *Writer, store: *Store, args: []const Value) !void {
    const pattern = args[1].as_slice();

    const all_keys = try store.keys(store.allocator, pattern);
    defer store.allocator.free(all_keys);
    try resp.write_list_len(writer, all_keys.len);
    // No yielding: `all_keys` borrows store-owned key bytes, and commands run
    // without a store lock. Yielding here would let another client delete a key
    // and invalidate the slice. Like Redis, KEYS blocks until the reply is built.
    for (all_keys) |key| {
        try resp.write_bulk_string(writer, key);
    }
}

pub fn exists(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    if (store.exists(key)) {
        try resp.write_int(writer, 1);
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn ttl(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    const exists_key = store.exists(key);

    if (!exists_key) {
        try resp.write_int(writer, -2);
        return;
    }
    // get_ttl is the absolute expiry in Unix ms; reply with the seconds left,
    // rounded to the nearest second like Redis.
    const expires_at = store.get_ttl(key) orelse return resp.write_int(writer, -1);
    const remaining_ms = @max(expires_at - store.clock.now().toMilliseconds(), 0);
    try resp.write_int(writer, @divTrunc(remaining_ms + 500, 1000));
}

pub fn pttl(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    if (!store.exists(key)) {
        try resp.write_int(writer, -2);
        return;
    }

    const expires_at = store.get_ttl(key) orelse return resp.write_int(writer, -1);
    const remaining_ms = @max(expires_at - store.clock.now().toMilliseconds(), 0);
    try resp.write_int(writer, remaining_ms);
}

pub fn scan(writer: *Writer, store: *Store, args: []const Value) !void {
    const cursor = args[1].as_u64() catch {
        return resp.write_error(writer, "ERR invalid cursor");
    };

    var pattern: []const u8 = "*";
    var count: usize = 10;
    var type_filter: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) {
        const option = args[i].as_slice();
        if (std.ascii.eqlIgnoreCase(option, "MATCH") and i + 1 < args.len) {
            pattern = args[i + 1].as_slice();
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(option, "COUNT") and i + 1 < args.len) {
            count = args[i + 1].as_usize() catch {
                return error.SyntaxError;
            };
            if (count == 0) return error.SyntaxError;
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(option, "TYPE") and i + 1 < args.len) {
            type_filter = args[i + 1].as_slice();
            i += 2;
        } else {
            return error.SyntaxError;
        }
    }

    const start: usize = if (cursor > std.math.maxInt(usize))
        store.capacity()
    else
        @intCast(cursor);

    var results: std.ArrayList([]const u8) = .empty;
    defer results.deinit(store.allocator);

    var next_cursor: u64 = 0;
    if (start < store.capacity()) {
        const now = store.clock.now().toMilliseconds();
        var iterator = store.scanIterator(start);
        var scanned: usize = 0;

        while (scanned < count) : (scanned += 1) {
            if (scanned % 1024 == 0 and store.commandExpired()) {
                return error.CommandTimeout;
            }
            const entry = iterator.next() orelse {
                next_cursor = 0;
                break;
            };
            next_cursor = if (iterator.slot_index >= store.capacity()) 0 else @intCast(iterator.slot_index);

            if (entry.expires_at) |expires_at| {
                if (now > expires_at) continue;
            }
            if (!string_match(pattern, entry.key)) continue;
            if (type_filter) |expected| {
                if (!scanTypeMatches(entry.value_type, expected)) continue;
            }
            try results.append(store.allocator, entry.key);
        }
    }

    var cursor_buffer: [20]u8 = undefined;
    const cursor_text = std.fmt.bufPrint(&cursor_buffer, "{d}", .{next_cursor}) catch unreachable;
    try resp.write_list_len(writer, 2);
    try resp.write_bulk_string(writer, cursor_text);
    try resp.write_list_len(writer, results.items.len);
    for (results.items) |key| {
        try resp.write_bulk_string(writer, key);
    }
}

fn scanTypeMatches(value_type: ValueType, expected: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(expected, "string")) {
        return value_type == .string or value_type == .short_string or value_type == .int;
    }
    if (std.ascii.eqlIgnoreCase(expected, "list")) return value_type == .list;
    if (std.ascii.eqlIgnoreCase(expected, "tseries-type") or std.ascii.eqlIgnoreCase(expected, "TSDB-TYPE")) {
        return value_type == .time_series;
    }
    if (std.ascii.eqlIgnoreCase(expected, "bloom_filter")) return value_type == .bloom_filter;
    if (std.ascii.eqlIgnoreCase(expected, "search_index")) return value_type == .search_index;
    return false;
}

pub fn persist(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    const result = store.persist(key);
    if (result) {
        try resp.write_int(writer, 1);
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn type_cmd(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();

    const obj = store.get(key);

    const type_str = if (obj) |o| switch (o.value) {
        .string, .short_string, .int => "string",
        .list => "list",
        .time_series => "tseries-type",
        .bloom_filter => "bloom_filter",
        .search_index => "search_index",
        .hash_map => "hash",
    } else "none";

    try resp.write_bulk_string(writer, type_str);
}

pub fn rename(writer: *Writer, store: *Store, args: []const Value) !void {
    const old_key = args[1].as_slice();
    const new_key = args[2].as_slice();

    const renamed = try store.rename_key(old_key, new_key);
    if (!renamed) {
        return error.KeyNotFound;
    }

    try resp.write_simple_string(writer, "OK");
}

pub fn randomkey(writer: *Writer, store: *Store, _: []const Value) !void {
    var random = std.Random.DefaultPrng.init(@intCast(0));
    const key = store.random_key(random.random());

    if (key) |k| {
        try resp.write_bulk_string(writer, k);
    } else {
        try resp.write_null(writer);
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

    // 10s left, in seconds (not the absolute expiry timestamp).
    try testing.expectEqualStrings(":10\r\n", writer.buffered());
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

    const ttl_val = store.get_ttl("mykey");
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

    try type_cmd(&writer, &store, &args);

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

    try store.set_int("mykey", 42);

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mykey" },
    };

    try type_cmd(&writer, &store, &args);

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

    _ = try store.create_list("mylist");

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mylist" },
    };

    try type_cmd(&writer, &store, &args);

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

    try type_cmd(&writer, &store, &args);

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

    try testing.expect(store.get("oldkey") == null);

    const new_value = store.get("newkey");
    try testing.expect(new_value != null);
    try testing.expectEqualStrings("value", new_value.?.value.short_string.as_slice());
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

test "KEYS aborts once the read-only command deadline has passed" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    try store.set("apple", "fruit");
    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    const args = [_]Value{ .{ .data = "KEYS" }, .{ .data = "*" } };

    store.command_deadline_ns = 0;

    try testing.expectError(error.CommandTimeout, keys(&writer, &store, &args));
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
    try store.set_int("count", 42);

    const args = [_]Value{
        .{ .data = "KEYS" },
        .{ .data = "*" },
    };

    try keys(&writer, &store, &args);

    const output = writer.buffered();
    // Should return array with 3 elements
    try testing.expect(mem.startsWith(u8, output, "*3\r\n"));
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

    try testing.expect(store.get("source") == null);

    const dest_value = store.get("dest");
    try testing.expect(dest_value != null);
    try testing.expectEqualStrings("source_value", dest_value.?.value.short_string.as_slice());
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

    const list = try store.create_list("source");
    try list.append(PrimitiveValue{ .int = 42 });

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "source" },
        .{ .data = "dest" },
    };

    try rename(&writer, &store, &args);

    try testing.expect(store.get("source") == null);

    const renamed_list = (try store.get_list("dest")).?;
    try testing.expectEqual(@as(usize, 1), renamed_list.len());

    const item = renamed_list.pop().?;
    switch (item) {
        .int => |value| try testing.expectEqual(@as(i64, 42), value),
        else => return error.TestUnexpectedResult,
    }
}

test "SCAN MATCH filters keys and finishes at cursor zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("alpha", "1");
    try store.set("beta", "2");
    try store.set("apple", "3");

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SCAN" },
        .{ .data = "0" },
        .{ .data = "MATCH" },
        .{ .data = "a*" },
        .{ .data = "COUNT" },
        .{ .data = "100" },
    };

    try scan(&writer, &store, &args);

    const output = writer.buffered();
    try testing.expect(mem.startsWith(u8, output, "*2\r\n$1\r\n0\r\n*2\r\n"));
    try testing.expect(mem.indexOf(u8, output, "alpha") != null);
    try testing.expect(mem.indexOf(u8, output, "apple") != null);
    try testing.expect(mem.indexOf(u8, output, "beta") == null);
}

test "SCAN TYPE filters by value type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("name", "value");
    _ = try store.create_list("items");

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SCAN" },
        .{ .data = "0" },
        .{ .data = "TYPE" },
        .{ .data = "list" },
        .{ .data = "COUNT" },
        .{ .data = "100" },
    };

    try scan(&writer, &store, &args);

    const output = writer.buffered();
    try testing.expect(mem.startsWith(u8, output, "*2\r\n$1\r\n0\r\n*1\r\n"));
    try testing.expect(mem.indexOf(u8, output, "items") != null);
    try testing.expect(mem.indexOf(u8, output, "name") == null);
}

test "SCAN rejects an invalid cursor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SCAN" },
        .{ .data = "not-a-number" },
    };

    try scan(&writer, &store, &args);

    try testing.expectEqualStrings("-ERR invalid cursor\r\n", writer.buffered());
}

test "PTTL reports remaining milliseconds and the missing-key sentinel" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "value");
    const now = Io.Clock.real.now(testing.io).toMilliseconds();
    _ = try store.expire("mykey", now + 10000);

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "PTTL" },
        .{ .data = "mykey" },
    };

    try pttl(&writer, &store, &args);

    const remaining = try std.fmt.parseInt(i64, mem.trim(u8, writer.buffered(), ":\r\n"), 10);
    try testing.expect(remaining > 0);
    try testing.expect(remaining <= 10000);

    writer = Writer.fixed(&buffer);
    const missing = [_]Value{
        .{ .data = "PTTL" },
        .{ .data = "missing" },
    };
    try pttl(&writer, &store, &missing);
    try testing.expectEqualStrings(":-2\r\n", writer.buffered());
}
