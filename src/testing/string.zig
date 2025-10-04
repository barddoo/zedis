const std = @import("std");
const Store = @import("../store.zig").Store;
const Value = @import("../parser.zig").Value;
const testing = std.testing;
const MockClient = @import("../test_utils.zig").MockClient;

test "SET command with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "hello" },
    };

    try client.testSet(&args);

    try testing.expectEqualStrings("+OK\r\n", client.getOutput());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("hello", stored_value.?.value.string);
}

test "SET command with integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "42" },
    };

    try client.testSet(&args);

    try testing.expectEqualStrings("+OK\r\n", client.getOutput());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 42), stored_value.?.value.int);
}

test "GET command with existing string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try client.testGet(&args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", client.getOutput());
}

test "GET command with existing integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{42});
    try store.set("key1", int_str);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try client.testGet(&args);

    try testing.expectEqualStrings("$2\r\n42\r\n", client.getOutput());
}

test "GET command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "nonexistent" },
    };

    try client.testGet(&args);

    try testing.expectEqualStrings("$-1\r\n", client.getOutput());
}

test "INCR command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try client.testIncr(&args);

    try testing.expectEqualStrings("$1\r\n1\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 1), stored_value.?.value.int);
}

test "INCR command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{5});
    try store.set("counter", int_str);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try client.testIncr(&args);

    try testing.expectEqualStrings("$1\r\n6\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 6), stored_value.?.value.int);
}

test "INCR command on string that represents integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("counter", "10");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try client.testIncr(&args);

    try testing.expectEqualStrings("$2\r\n11\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 11), stored_value.?.value.int);
}

test "INCR command on non-integer string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "key1" },
    };

    try client.testIncr(&args);

    try testing.expectEqualStrings("-ERR value is not an integer or out of range\r\n", client.getOutput());
}

test "DECR command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try client.testDecr(&args);

    try testing.expectEqualStrings("$2\r\n-1\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -1), stored_value.?.value.int);
}

test "DECR command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{10});
    try store.set("counter", int_str);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try client.testDecr(&args);

    try testing.expectEqualStrings("$1\r\n9\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 9), stored_value.?.value.int);
}

test "DEL command with single existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "value1");

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
    };

    try client.testDel(&args);

    try testing.expectEqualStrings(":1\r\n", client.getOutput());

    const stored_value = store.get("key1");
    try testing.expect(stored_value == null);
}

test "DEL command with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{42});
    try store.set("key3", int_str);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
        .{ .data = "nonexistent" },
    };

    try client.testDel(&args);

    try testing.expectEqualStrings(":3\r\n", client.getOutput());

    try testing.expect(store.get("key1") == null);
    try testing.expect(store.get("key2") == null);
    try testing.expect(store.get("key3") == null);
}

test "DEL command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "nonexistent" },
    };

    try client.testDel(&args);

    try testing.expectEqualStrings(":0\r\n", client.getOutput());
}

test "SETEX command with valid expiration time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "SETEX" },
        .{ .data = "key1" },
        .{ .data = "10" },
        .{ .data = "value1" },
    };

    try client.testSetex(&args);

    try testing.expectEqualStrings("$2\r\nOK\r\n", client.getOutput());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("value1", stored_value.?.value.string);

    // Check that expiration is set
    try testing.expect(stored_value.?.expiration != null);
    try testing.expect(stored_value.?.expiration.? > std.time.milliTimestamp());
}

test "SETEX command with invalid expiration time" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "SETEX" },
        .{ .data = "key1" },
        .{ .data = "-1" },
        .{ .data = "value1" },
    };

    try client.testSetex(&args);

    try testing.expectEqualStrings("-ERR invalid expire time in SETEX\r\n", client.getOutput());
}

test "SETNX command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "key1" },
        .{ .data = "value1" },
    };

    try client.testSetnx(&args);

    try testing.expectEqualStrings(":1\r\n", client.getOutput());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("value1", stored_value.?.value.string);
}

test "SETNX command on existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "existing");

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "key1" },
        .{ .data = "new_value" },
    };

    try client.testSetnx(&args);

    try testing.expectEqualStrings(":0\r\n", client.getOutput());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("existing", stored_value.?.value.string);
}

test "INCRBY command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "counter" },
        .{ .data = "5" },
    };

    try client.testIncrby(&args);

    try testing.expectEqualStrings("$1\r\n5\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 5), stored_value.?.value.int);
}

test "INCRBY command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{10});
    try store.set("counter", int_str);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "counter" },
        .{ .data = "7" },
    };

    try client.testIncrby(&args);

    try testing.expectEqualStrings("$2\r\n17\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 17), stored_value.?.value.int);
}

test "INCRBY command with negative increment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{10});
    try store.set("counter", int_str);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "counter" },
        .{ .data = "-3" },
    };

    try client.testIncrby(&args);

    try testing.expectEqualStrings("$1\r\n7\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 7), stored_value.?.value.int);
}

test "DECRBY command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "counter" },
        .{ .data = "5" },
    };

    try client.testDecrby(&args);

    try testing.expectEqualStrings("$2\r\n-5\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -5), stored_value.?.value.int);
}

test "DECRBY command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{20});
    try store.set("counter", int_str);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "counter" },
        .{ .data = "7" },
    };

    try client.testDecrby(&args);

    try testing.expectEqualStrings("$2\r\n13\r\n", client.getOutput());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 13), stored_value.?.value.int);
}

test "INCRBYFLOAT command on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "key1" },
        .{ .data = "2.5" },
    };

    try client.testIncrbyfloat(&args);

    const output = client.getOutput();
    try testing.expect(std.mem.startsWith(u8, output, "$"));
    try testing.expect(std.mem.indexOf(u8, output, "2.5") != null);
}

test "INCRBYFLOAT command on existing float string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "10.5");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "key1" },
        .{ .data = "2.5" },
    };

    try client.testIncrbyfloat(&args);

    const output = client.getOutput();
    try testing.expect(std.mem.startsWith(u8, output, "$"));
    try testing.expect(std.mem.indexOf(u8, output, "13") != null);
}

test "INCRBYFLOAT command on existing integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    var buf: [20]u8 = undefined;
    const int_str = try std.fmt.bufPrint(&buf, "{d}", .{10});
    try store.set("key1", int_str);

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "key1" },
        .{ .data = "1.5" },
    };

    try client.testIncrbyfloat(&args);

    const output = client.getOutput();
    try testing.expect(std.mem.startsWith(u8, output, "$"));
    try testing.expect(std.mem.indexOf(u8, output, "11.5") != null);
}

test "INCRBYFLOAT command with negative increment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "10.5");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "key1" },
        .{ .data = "-2.5" },
    };

    try client.testIncrbyfloat(&args);

    const output = client.getOutput();
    try testing.expect(std.mem.startsWith(u8, output, "$"));
    try testing.expect(std.mem.indexOf(u8, output, "8") != null);
}

test "MSET command with multiple key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "MSET" },
        .{ .data = "key1" },
        .{ .data = "value1" },
        .{ .data = "key2" },
        .{ .data = "value2" },
        .{ .data = "key3" },
        .{ .data = "value3" },
    };

    try client.testMset(&args);

    try testing.expectEqualStrings("$2\r\nOK\r\n", client.getOutput());

    const value1 = store.get("key1");
    try testing.expect(value1 != null);
    try testing.expectEqualStrings("value1", value1.?.value.string);

    const value2 = store.get("key2");
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("value2", value2.?.value.string);

    const value3 = store.get("key3");
    try testing.expect(value3 != null);
    try testing.expectEqualStrings("value3", value3.?.value.string);
}

test "MSET command overwrites existing keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    try store.set("key1", "old_value");
    try store.set("key2", "old_value2");

    const args = [_]Value{
        .{ .data = "MSET" },
        .{ .data = "key1" },
        .{ .data = "new_value1" },
        .{ .data = "key2" },
        .{ .data = "new_value2" },
    };

    try client.testMset(&args);

    try testing.expectEqualStrings("$2\r\nOK\r\n", client.getOutput());

    const value1 = store.get("key1");
    try testing.expect(value1 != null);
    try testing.expectEqualStrings("new_value1", value1.?.value.string);

    const value2 = store.get("key2");
    try testing.expect(value2 != null);
    try testing.expectEqualStrings("new_value2", value2.?.value.string);
}

test "MSET command with single key-value pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var client = MockClient.initLegacy(allocator, &store);
    defer client.deinit();

    const args = [_]Value{
        .{ .data = "MSET" },
        .{ .data = "key1" },
        .{ .data = "value1" },
    };

    try client.testMset(&args);

    try testing.expectEqualStrings("$2\r\nOK\r\n", client.getOutput());

    const value1 = store.get("key1");
    try testing.expect(value1 != null);
    try testing.expectEqualStrings("value1", value1.?.value.string);
}
