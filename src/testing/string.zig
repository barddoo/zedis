const std = @import("std");
const Store = @import("../store.zig").Store;
const Value = @import("../parser.zig").Value;
const testing = std.testing;
const string_commands = @import("../commands/string.zig");

test "SET command with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "hello" },
    };

    try string_commands.set(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("hello", stored_value.?.value.short_string.asSlice());
}

test "SET command with integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "42" },
    };

    try string_commands.set(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 42), stored_value.?.value.int);
}

test "GET command with existing string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try string_commands.get(&writer, &store, &args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());
}

test "GET command with existing integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.setInt("key1", 42);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try string_commands.get(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n42\r\n", writer.buffered());
}

test "GET command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "nonexistent" },
    };

    try string_commands.get(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "INCR command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try string_commands.incr(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n1\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 1), stored_value.?.value.int);
}

test "INCR command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.setInt("counter", 5);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try string_commands.incr(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n6\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 6), stored_value.?.value.int);
}

test "INCR command on string that represents integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("counter", "10");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try string_commands.incr(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n11\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 11), stored_value.?.value.int);
}

test "INCR command on non-integer string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "key1" },
    };

    const result = string_commands.incr(&writer, &store, &args);
    try testing.expectError(error.ValueNotInteger, result);
}

test "DECR command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try string_commands.decr(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n-1\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -1), stored_value.?.value.int);
}

test "DECR command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.setInt("counter", 10);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try string_commands.decr(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n9\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 9), stored_value.?.value.int);
}

test "DEL command with single existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("key1", "value1");

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
    };

    try string_commands.del(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value == null);
}

test "DEL command with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.setInt("key3", 42);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
        .{ .data = "nonexistent" },
    };

    try string_commands.del(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    try testing.expect(store.get("key1") == null);
    try testing.expect(store.get("key2") == null);
    try testing.expect(store.get("key3") == null);
}

test "DEL command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "nonexistent" },
    };

    try string_commands.del(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "APPEND command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "APPEND" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try string_commands.append(&writer, &store, &args);

    try testing.expectEqualStrings(":5\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.asSlice());
}

test "APPEND command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "Hello");

    const args = [_]Value{
        .{ .data = "APPEND" },
        .{ .data = "mykey" },
        .{ .data = " World" },
    };

    try string_commands.append(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello World", stored_value.?.value.short_string.asSlice());
}

test "STRLEN command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "Hello World");

    const args = [_]Value{
        .{ .data = "STRLEN" },
        .{ .data = "mykey" },
    };

    try string_commands.strlen(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());
}

test "STRLEN command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "STRLEN" },
        .{ .data = "nonexistent" },
    };

    try string_commands.strlen(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "GETSET command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "Hello");

    const args = [_]Value{
        .{ .data = "GETSET" },
        .{ .data = "mykey" },
        .{ .data = "World" },
    };

    try string_commands.getset(&writer, &store, &args);

    try testing.expectEqualStrings("$5\r\nHello\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.asSlice());
}

test "GETSET command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GETSET" },
        .{ .data = "mykey" },
        .{ .data = "World" },
    };

    try string_commands.getset(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.asSlice());
}

test "MGET command with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.setInt("key2", 42);

    const args = [_]Value{
        .{ .data = "MGET" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
    };

    try string_commands.mget(&writer, &store, &args);

    try testing.expectEqualStrings("*3\r\n$6\r\nvalue1\r\n$2\r\n42\r\n$-1\r\n", writer.buffered());
}

test "MSET command with multiple key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "MSET" },
        .{ .data = "key1" },
        .{ .data = "value1" },
        .{ .data = "key2" },
        .{ .data = "value2" },
    };

    try string_commands.mset(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const v1 = store.get("key1");
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?.value.short_string.asSlice());

    const v2 = store.get("key2");
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?.value.short_string.asSlice());
}

test "SETEX command sets key with expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SETEX" },
        .{ .data = "mykey" },
        .{ .data = "10" },
        .{ .data = "Hello" },
    };

    try string_commands.setex(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.asSlice());
}

test "SETNX command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try string_commands.setnx(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.asSlice());
}

test "SETNX command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "World");

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try string_commands.setnx(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.asSlice());
}

test "INCRBY command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "mykey" },
        .{ .data = "5" },
    };

    try string_commands.incrby(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n5\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 5), stored_value.?.value.int);
}

test "INCRBY command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.setInt("mykey", 10);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "mykey" },
        .{ .data = "5" },
    };

    try string_commands.incrby(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n15\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 15), stored_value.?.value.int);
}

test "DECRBY command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "mykey" },
        .{ .data = "3" },
    };

    try string_commands.decrby(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n-3\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -3), stored_value.?.value.int);
}

test "DECRBY command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.setInt("mykey", 10);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "mykey" },
        .{ .data = "3" },
    };

    try string_commands.decrby(&writer, &store, &args);

    try testing.expectEqualStrings("$1\r\n7\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 7), stored_value.?.value.int);
}

test "INCRBYFLOAT command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "2.5" },
    };

    try string_commands.incrbyfloat(&writer, &store, &args);

    try testing.expectEqualStrings("$3\r\n2.5\r\n", writer.buffered());
}

test "INCRBYFLOAT command on existing float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "10.5");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "0.1" },
    };

    try string_commands.incrbyfloat(&writer, &store, &args);

    // Result should be "10.6" (trailing zeros removed)
    try testing.expectEqualStrings("$4\r\n10.6\r\n", writer.buffered());
}

test "INCRBYFLOAT command with negative increment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "5.0");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "-2.0" },
    };

    try string_commands.incrbyfloat(&writer, &store, &args);

    // Result should be "3" (trailing zeros and decimal point removed)
    try testing.expectEqualStrings("$1\r\n3\r\n", writer.buffered());
}
