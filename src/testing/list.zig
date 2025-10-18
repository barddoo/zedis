const std = @import("std");
const Store = @import("../store.zig").Store;
const Value = @import("../parser.zig").Value;
const testing = std.testing;
const list_commands = @import("../commands/list.zig");

// LPUSH Tests
test "LPUSH single element to new list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "world" },
    };

    try list_commands.lpush(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    // Verify the list was created and contains the element
    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "LPUSH multiple elements to new list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "three" },
        .{ .data = "two" },
        .{ .data = "one" },
    };

    try list_commands.lpush(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    // Verify the list has 3 elements
    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len());
}

test "LPUSH to existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // First, add some elements
    const args1 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "initial" },
    };
    try list_commands.lpush(&writer, &store, &args1);
    writer = std.Io.Writer.fixed(&buffer);

    // Then add more elements
    const args2 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "second" },
        .{ .data = "first" },
    };
    try list_commands.lpush(&writer, &store, &args2);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len());
}

// RPUSH Tests
test "RPUSH single element to new list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };

    try list_commands.rpush(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "RPUSH multiple elements to new list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };

    try list_commands.rpush(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 3), list.?.len());
}

// LPOP Tests
test "LPOP from list with single element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // First create a list with one element
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try list_commands.lpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Then pop the element
    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try list_commands.lpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());

    // List should be empty now
    const list = try store.getList("mylist");
    try testing.expect(list == null or list.?.len() == 0);
}

test "LPOP from non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "nonexistent" },
    };

    try list_commands.lpop(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LPOP with count from list with multiple elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create a list with multiple elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "three" },
        .{ .data = "two" },
        .{ .data = "one" },
    };
    try list_commands.lpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Pop 2 elements
    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
        .{ .data = "2" },
    };
    try list_commands.lpop(&writer, &store, &pop_args);

    // Should return an array with 2 elements
    try testing.expectEqualStrings("*2\r\n$3\r\none\r\n$3\r\ntwo\r\n", writer.buffered());

    // List should have 1 element left
    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "LPOP with count of 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create a list with elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try list_commands.lpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Pop 0 elements
    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
        .{ .data = "0" },
    };
    try list_commands.lpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

// RPOP Tests
test "RPOP from list with single element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // First create a list with one element
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Then pop the element
    const pop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
    };
    try list_commands.rpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());
}

test "RPOP with count from list with multiple elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create a list with multiple elements
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Pop 2 elements from the right
    const pop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
        .{ .data = "2" },
    };
    try list_commands.rpop(&writer, &store, &pop_args);

    // Should return an array with 2 elements (in reverse order from LPOP)
    try testing.expectEqualStrings("*2\r\n$5\r\nthree\r\n$3\r\ntwo\r\n", writer.buffered());

    // List should have 1 element left
    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

// LLEN Tests
test "LLEN on existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create a list with elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.lpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Check length
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try list_commands.llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "LLEN on non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "nonexistent" },
    };

    try list_commands.llen(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "LLEN on empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create a list and then pop all elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "temp" },
    };
    try list_commands.lpush(&writer, &store, &push_args);

    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try list_commands.lpop(&writer, &store, &pop_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Check length of now-empty list
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try list_commands.llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "Mixed LPUSH and RPUSH operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // LPUSH "middle"
    const lpush_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "middle" },
    };
    try list_commands.lpush(&writer, &store, &lpush_args);
    writer = std.Io.Writer.fixed(&buffer);

    // LPUSH "left"
    const lpush_args2 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "left" },
    };
    try list_commands.lpush(&writer, &store, &lpush_args2);
    writer = std.Io.Writer.fixed(&buffer);

    // RPUSH "right"
    const rpush_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "right" },
    };
    try list_commands.rpush(&writer, &store, &rpush_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Should have 3 elements in order: left, middle, right
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try list_commands.llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "LPOP and RPOP from the same list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // LPOP should get "one"
    const lpop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try list_commands.lpop(&writer, &store, &lpop_args);
    try testing.expectEqualStrings("$3\r\none\r\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);

    // RPOP should get "three"
    const rpop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
    };
    try list_commands.rpop(&writer, &store, &rpop_args);
    try testing.expectEqualStrings("$5\r\nthree\r\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);

    // Should have 1 element left ("two")
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try list_commands.llen(&writer, &store, &llen_args);
    try testing.expectEqualStrings(":1\r\n", writer.buffered());
}

// LINDEX Tests
test "LINDEX get first element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Get first element (index 0)
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "0" },
    };
    try list_commands.lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$3\r\none\r\n", writer.buffered());
}

test "LINDEX get last element with negative index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Get last element (index -1)
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
    };
    try list_commands.lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$5\r\nthree\r\n", writer.buffered());
}

test "LINDEX with out of range index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Try to get element at index 10
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "10" },
    };
    try list_commands.lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LINDEX on non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
    };

    try list_commands.lindex(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

// LSET Tests
test "LSET update element at index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Set element at index 1 to "TWO"
    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "1" },
        .{ .data = "TWO" },
    };
    try list_commands.lset(&writer, &store, &lset_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);

    // Verify the element was updated
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "1" },
    };
    try list_commands.lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$3\r\nTWO\r\n", writer.buffered());
}

test "LSET with negative index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Set last element using -1
    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
        .{ .data = "THREE" },
    };
    try list_commands.lset(&writer, &store, &lset_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    writer = std.Io.Writer.fixed(&buffer);

    // Verify the last element was updated
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
    };
    try list_commands.lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$5\r\nTHREE\r\n", writer.buffered());
}

test "LSET on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
        .{ .data = "value" },
    };

    const result = list_commands.lset(&writer, &store, &args);
    try testing.expectError(error.NoSuchKey, result);
}

test "LSET with out of range index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Try to set element at index 10
    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "10" },
        .{ .data = "value" },
    };

    const result = list_commands.lset(&writer, &store, &lset_args);
    try testing.expectError(error.KeyNotFound, result);
}

// LRANGE Tests
test "LRANGE get all elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Get all elements (0 to -1)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "0" },
        .{ .data = "-1" },
    };
    try list_commands.lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*3\r\n$3\r\none\r\n$3\r\ntwo\r\n$5\r\nthree\r\n", writer.buffered());
}

test "LRANGE get subset of elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three, four, five
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
        .{ .data = "four" },
        .{ .data = "five" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Get elements from index 1 to 3
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "1" },
        .{ .data = "3" },
    };
    try list_commands.lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*3\r\n$3\r\ntwo\r\n$5\r\nthree\r\n$4\r\nfour\r\n", writer.buffered());
}

test "LRANGE with negative indices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three, four, five
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
        .{ .data = "four" },
        .{ .data = "five" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Get last 2 elements (-2 to -1)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "-2" },
        .{ .data = "-1" },
    };
    try list_commands.lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*2\r\n$4\r\nfour\r\n$4\r\nfive\r\n", writer.buffered());
}

test "LRANGE on non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
        .{ .data = "-1" },
    };

    try list_commands.lrange(&writer, &store, &args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LRANGE with out of range indices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Try to get elements from 10 to 20 (out of range)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "10" },
        .{ .data = "20" },
    };
    try list_commands.lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LRANGE with reversed range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try list_commands.rpush(&writer, &store, &push_args);
    writer = std.Io.Writer.fixed(&buffer);

    // Try reversed range (start > stop)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "2" },
        .{ .data = "1" },
    };
    try list_commands.lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}
