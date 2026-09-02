const std = @import("std");
const storeModule = @import("../store.zig");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const Io = std.Io;
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Writer = Io.Writer;
const testing = std.testing;
const Clock = @import("../clock.zig");

pub fn set(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = args[2].as_slice();

    try store.set(key, value);

    try resp.write_ok(writer);
}

pub fn get(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = store.get(key);

    if (value) |v| {
        switch (v.value) {
            .string => |s| try resp.write_bulk_string(writer, s),
            .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
            .int => |i| {
                try resp.write_int_bulk_string(writer, i);
            },
            .list, .time_series, .bloom_filter, .search_index => return error.WrongType,
        }
    } else {
        try resp.write_null(writer);
    }
}

pub fn incr(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const new_value = try incr_decr(store, key, 1);

    try resp.write_int_bulk_string(writer, new_value);
}

pub fn decr(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const new_value = try incr_decr(store, key, -1);

    try resp.write_int_bulk_string(writer, new_value);
}

fn incr_decr(store_ptr: *Store, key: []const u8, value: i64) !i64 {
    const current_value = store_ptr.get(key);
    if (current_value) |v| {
        var new_value: i64 = undefined;

        switch (v.value) {
            .string => {
                const intValue = std.fmt.parseInt(i64, v.value.string, 10) catch {
                    return error.ValueNotInteger;
                };
                new_value = std.math.add(i64, intValue, value) catch {
                    return error.ValueNotInteger;
                };
            },
            .short_string => {
                const intValue = std.fmt.parseInt(i64, v.value.short_string.as_slice(), 10) catch {
                    return error.ValueNotInteger;
                };
                new_value = std.math.add(i64, intValue, value) catch {
                    return error.ValueNotInteger;
                };
            },
            .int => {
                new_value = std.math.add(i64, v.value.int, value) catch {
                    return error.ValueNotInteger;
                };
            },
            else => return error.WrongType,
        }

        const int_object = ZedisObject{ .value = .{ .int = new_value } };
        try store_ptr.put_object(key, int_object);

        return new_value;
    } else {
        // Redis behavior: non-existent key is treated as 0, then the operation is applied
        const new_value = std.math.add(i64, 0, value) catch {
            return error.ValueNotInteger;
        };
        try store_ptr.set_int(key, new_value);
        return new_value;
    }
}

pub fn del(writer: *Writer, store: *Store, args: []const Value) !void {
    var deleted: u32 = 0;
    for (args[1..]) |key| {
        if (store.delete(key.as_slice())) {
            deleted += 1;
        }
    }

    try resp.write_int(writer, deleted);
}

pub fn expire(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const expiration_seconds = args[2].as_int() catch {
        return resp.write_int(writer, 0);
    };

    const result = if (expiration_seconds < 0)
        store.delete(key)
    else blk: {
        const ts = store.clock.now();
        const current_time = ts.toMilliseconds();

        break :blk store.expire(key, current_time + (expiration_seconds * 1000));
    };

    try resp.write_int(writer, @intFromBool(try result));
}

pub fn expire_at(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const ts = store.clock.now();
    const current_time = ts.toMilliseconds();
    const expiration_timestamp = args[2].as_int() catch {
        return resp.write_int(writer, 0);
    };

    const result = if (expiration_timestamp <= current_time)
        store.delete(key)
    else
        store.expire(key, expiration_timestamp) catch false;

    try resp.write_int(writer, @intFromBool(result));
}

pub fn append(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const append_value = args[2].as_slice();

    const current_value = store.get(key);
    var new_value: []const u8 = undefined;
    var needs_free = false;

    if (current_value) |v| {
        const current_str = switch (v.value) {
            .string => |s| s,
            .short_string => |ss| ss.as_slice(),
            .int => |i| blk: {
                var buf: [21]u8 = undefined;
                break :blk std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            },
            else => return error.WrongType,
        };

        // Concatenate current value with append value
        const concatenated = try std.fmt.allocPrint(store.allocator, "{s}{s}", .{ current_str, append_value });
        new_value = concatenated;
        needs_free = true;
    } else {
        new_value = append_value;
    }

    defer if (needs_free) store.allocator.free(new_value);
    try store.set(key, new_value);

    try resp.write_int(writer, new_value.len);
}

pub fn strlen(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = store.get(key);

    if (value) |v| {
        const len: usize = switch (v.value) {
            .string => |s| s.len,
            .short_string => |ss| ss.len,
            .int => |i| blk: {
                var buf: [21]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                break :blk str.len;
            },
            else => return error.WrongType,
        };
        try resp.write_int(writer, len);
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn getset(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const new_value = args[2].as_slice();

    // Get old value
    const old_value = store.get(key);

    if (old_value) |v| {
        switch (v.value) {
            .string => |s| try resp.write_bulk_string(writer, s),
            .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
            .int => |i| try resp.write_int_bulk_string(writer, i),
            else => return error.WrongType,
        }
    } else {
        try resp.write_null(writer);
    }

    // Set new value
    try store.set(key, new_value);
}

pub fn mget(writer: *Writer, store: *Store, args: []const Value) !void {
    // Write array header
    try resp.write_list_len(writer, args.len - 1);

    // Get each key
    for (args[1..]) |key_arg| {
        const key = key_arg.as_slice();
        const value = store.get(key);

        if (value) |v| {
            switch (v.value) {
                .string => |s| try resp.write_bulk_string(writer, s),
                .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
                .int => |i| try resp.write_int_bulk_string(writer, i),
                else => try resp.write_null(writer), // Lists return null
            }
        } else {
            try resp.write_null(writer);
        }
    }
}

pub fn mset(writer: *Writer, store: *Store, args: []const Value) !void {
    // Args format: MSET key1 value1 key2 value2 ...
    if (args.len % 2 != 1) {
        return error.InvalidArgument;
    }

    // Set all key-value pairs
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const key = args[i].as_slice();
        const value = args[i + 1].as_slice();
        try store.set(key, value);
    }

    try resp.write_ok(writer);
}

pub fn setex(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const seconds = args[2].as_int() catch {
        return error.ValueNotInteger;
    };
    const value = args[3].as_slice();

    // Set the value
    try store.set(key, value);

    // Set expiration
    if (seconds > 0) {
        const ts = store.clock.now();
        const now = ts.toMilliseconds();
        const expiration_time = now + (seconds * 1000);
        _ = try store.expire(key, expiration_time);
    }

    try resp.write_ok(writer);
}

pub fn setnx(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = args[2].as_slice();

    const exists = store.get(key) != null;

    if (!exists) {
        try store.set(key, value);
        try resp.write_int(writer, 1);
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn incrby(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const increment = args[2].as_int() catch {
        return error.ValueNotInteger;
    };

    const new_value = try incr_decr(store, key, increment);
    try resp.write_int_bulk_string(writer, new_value);
}

pub fn decrby(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const decrement = args[2].as_int() catch {
        return error.ValueNotInteger;
    };

    const new_value = try incr_decr(store, key, -decrement);
    try resp.write_int_bulk_string(writer, new_value);
}

pub fn incrbyfloat(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const increment_str = args[2].as_slice();

    // Parse increment as float
    const increment = std.fmt.parseFloat(f64, increment_str) catch {
        return error.InvalidFloat;
    };

    // Get current value
    const current_value = store.get(key);
    var current_float: f64 = 0.0;

    if (current_value) |v| {
        switch (v.value) {
            .string => |s| {
                current_float = std.fmt.parseFloat(f64, s) catch {
                    return error.InvalidFloat;
                };
            },
            .short_string => |ss| {
                current_float = std.fmt.parseFloat(f64, ss.as_slice()) catch {
                    return error.InvalidFloat;
                };
            },
            .int => |i| {
                current_float = @floatFromInt(i);
            },
            else => return error.WrongType,
        }
    }

    // Compute new value
    const new_float = current_float + increment;

    // Format to string with up to 17 decimal places, removing trailing zeros
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d:.17}", .{new_float}) catch {
        return error.Overflow;
    };

    // Remove trailing zeros and trailing decimal point
    var end = formatted.len;
    if (std.mem.indexOf(u8, formatted, ".")) |_| {
        while (end > 0 and formatted[end - 1] == '0') {
            end -= 1;
        }
        if (end > 0 and formatted[end - 1] == '.') {
            end -= 1;
        }
    }

    const result = formatted[0..end];

    // Store as string
    try store.set(key, result);

    // Return as bulk string
    try resp.write_bulk_string(writer, result);
}

test "SET command with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "hello" },
    };

    try set(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("hello", stored_value.?.value.short_string.as_slice());
}

test "SET command with integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "42" },
    };

    try set(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("42", stored_value.?.value.short_string.as_slice());
}

test "GET command with existing string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());
}

test "GET command with existing integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("key1", 42);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n42\r\n", writer.buffered());
}

test "GET command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "nonexistent" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "INCR command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try incr(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n1\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 1), stored_value.?.value.int);
}

test "INCR command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("counter", 5);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try incr(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n6\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 6), stored_value.?.value.int);
}

test "INCR command on string that represents integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("counter", "10");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try incr(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n11\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 11), stored_value.?.value.int);
}

test "INCR command on non-integer string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "key1" },
    };

    const result = incr(&writer, &store, &args);
    try testing.expectError(error.ValueNotInteger, result);
}

test "DECR command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try decr(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n-1\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -1), stored_value.?.value.int);
}

test "DECR command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("counter", 10);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try decr(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n9\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 9), stored_value.?.value.int);
}

test "DEL command with single existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "value1");

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
    };

    try del(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value == null);
}

test "DEL command with multiple keys" {
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
    try store.set_int("key3", 42);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
        .{ .data = "nonexistent" },
    };

    try del(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    try testing.expect(store.get("key1") == null);
    try testing.expect(store.get("key2") == null);
    try testing.expect(store.get("key3") == null);
}

test "DEL command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "nonexistent" },
    };

    try del(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "APPEND command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "APPEND" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try append(&writer, &store, &args);

    try testing.expectEqualStrings(":5\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.as_slice());
}

test "APPEND command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "Hello");

    const args = [_]Value{
        .{ .data = "APPEND" },
        .{ .data = "mykey" },
        .{ .data = " World" },
    };

    try append(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello World", stored_value.?.value.short_string.as_slice());
}

test "STRLEN command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "Hello World");

    const args = [_]Value{
        .{ .data = "STRLEN" },
        .{ .data = "mykey" },
    };

    try strlen(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());
}

test "STRLEN command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "STRLEN" },
        .{ .data = "nonexistent" },
    };

    try strlen(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "GETSET command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "Hello");

    const args = [_]Value{
        .{ .data = "GETSET" },
        .{ .data = "mykey" },
        .{ .data = "World" },
    };

    try getset(&writer, &store, &args);

    try testing.expectEqualStrings("$5\r\nHello\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.as_slice());
}

test "GETSET command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GETSET" },
        .{ .data = "mykey" },
        .{ .data = "World" },
    };

    try getset(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.as_slice());
}

test "MGET command with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.set_int("key2", 42);

    const args = [_]Value{
        .{ .data = "MGET" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
    };

    try mget(&writer, &store, &args);

    try testing.expectEqualStrings("*3\r\n$6\r\nvalue1\r\n$2\r\n42\r\n$-1\r\n", writer.buffered());
}

test "MSET command with multiple key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "MSET" },
        .{ .data = "key1" },
        .{ .data = "value1" },
        .{ .data = "key2" },
        .{ .data = "value2" },
    };

    try mset(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const v1 = store.get("key1");
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?.value.short_string.as_slice());

    const v2 = store.get("key2");
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?.value.short_string.as_slice());
}

test "SETEX command sets key with expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SETEX" },
        .{ .data = "mykey" },
        .{ .data = "10" },
        .{ .data = "Hello" },
    };

    try setex(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.as_slice());
}

test "SETNX command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try setnx(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.as_slice());
}

test "SETNX command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "World");

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try setnx(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.as_slice());
}

test "INCRBY command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "mykey" },
        .{ .data = "5" },
    };

    try incrby(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n5\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 5), stored_value.?.value.int);
}

test "INCRBY command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("mykey", 10);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "mykey" },
        .{ .data = "5" },
    };

    try incrby(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n15\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 15), stored_value.?.value.int);
}

test "DECRBY command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "mykey" },
        .{ .data = "3" },
    };

    try decrby(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n-3\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -3), stored_value.?.value.int);
}

test "DECRBY command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("mykey", 10);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "mykey" },
        .{ .data = "3" },
    };

    try decrby(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n7\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 7), stored_value.?.value.int);
}

test "INCRBYFLOAT command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "2.5" },
    };

    try incrbyfloat(&writer, &store, &args);

    try testing.expectEqualStrings("$3\r\n2.5\r\n", writer.buffered());
}

test "INCRBYFLOAT command on existing float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "10.5");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "0.1" },
    };

    try incrbyfloat(&writer, &store, &args);

    // Result should be "10.6" (trailing zeros removed)
    try testing.expectEqualStrings("$4\r\n10.6\r\n", writer.buffered());
}

test "INCRBYFLOAT command with negative increment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "5.0");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "-2.0" },
    };

    try incrbyfloat(&writer, &store, &args);

    // Result should be "3" (trailing zeros and decimal point removed)
    try testing.expectEqualStrings("$1\r\n3\r\n", writer.buffered());
}
