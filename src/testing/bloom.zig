const std = @import("std");
const Store = @import("../store.zig").Store;
const Value = @import("../parser.zig").Value;
const testing = std.testing;
const bloom_commands = @import("../commands/bloom.zig");
const Io = std.Io;
const Writer = Io.Writer;
const Clock = @import("../clock.zig");

test "BF.RESERVE command with valid parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" }, // error rate
        .{ .data = "1000" }, // capacity
    };

    try bloom_commands.bf_reserve(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    // Verify the bloom filter was created
    const bf = try store.getBloomFilter("bloom1");
    try testing.expect(bf != null);
}

test "BF.RESERVE command with invalid error rate too high" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "1.5" }, // invalid error rate > 1.0
        .{ .data = "1000" },
    };

    try testing.expectError(error.InvalidArgument, bloom_commands.bf_reserve(&writer, &store, &args));
}

test "BF.RESERVE command with missing arguments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        // Missing error rate and capacity
    };

    try testing.expectError(error.WrongNumberOfArguments, bloom_commands.bf_reserve(&writer, &store, &args));
}

test "BF.ADD command with new item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Now add an item
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const args = [_]Value{
        .{ .data = "BF.ADD" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
    };

    try bloom_commands.bf_add(&writer2, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer2.buffered()); // 1 means newly added
}

test "BF.ADD command with existing item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Add an item first
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const add_args1 = [_]Value{
        .{ .data = "BF.ADD" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
    };

    try bloom_commands.bf_add(&writer2, &store, &add_args1);

    // Add the same item again
    var buffer3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buffer3);

    const add_args2 = [_]Value{
        .{ .data = "BF.ADD" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
    };

    try bloom_commands.bf_add(&writer3, &store, &add_args2);

    try testing.expectEqualStrings(":0\r\n", writer3.buffered()); // 0 means already existed
}

test "BF.EXISTS command with existing item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Add an item
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const add_args = [_]Value{
        .{ .data = "BF.ADD" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
    };

    try bloom_commands.bf_add(&writer2, &store, &add_args);

    // Check if item exists
    var buffer3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buffer3);

    const exists_args = [_]Value{
        .{ .data = "BF.EXISTS" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
    };

    try bloom_commands.bf_exists(&writer3, &store, &exists_args);

    try testing.expectEqualStrings(":1\r\n", writer3.buffered()); // 1 means may exist
}

test "BF.EXISTS command with non-existing item" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Check if non-existing item exists
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const exists_args = [_]Value{
        .{ .data = "BF.EXISTS" },
        .{ .data = "bloom1" },
        .{ .data = "nonexistent" },
    };

    try bloom_commands.bf_exists(&writer2, &store, &exists_args);

    try testing.expectEqualStrings(":0\r\n", writer2.buffered()); // 0 means definitely doesn't exist
}

test "BF.MADD command with multiple items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Add multiple items
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const args = [_]Value{
        .{ .data = "BF.MADD" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
        .{ .data = "item2" },
        .{ .data = "item3" },
    };

    try bloom_commands.bf_madd(&writer2, &store, &args);

    // Should return array with 3 items, all 1 (newly added)
    try testing.expectEqualStrings("*3\r\n:1\r\n:1\r\n:1\r\n", writer2.buffered());
}

test "BF.MEXISTS command with multiple items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Add some items
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const add_args = [_]Value{
        .{ .data = "BF.ADD" },
        .{ .data = "bloom1" },
        .{ .data = "item1" },
    };

    try bloom_commands.bf_add(&writer2, &store, &add_args);

    // Check multiple items (some existing, some not)
    var buffer3: [4096]u8 = undefined;
    var writer3 = Writer.fixed(&buffer3);

    const exists_args = [_]Value{
        .{ .data = "BF.MEXISTS" },
        .{ .data = "bloom1" },
        .{ .data = "item1" }, // should exist
        .{ .data = "item2" }, // should not exist
    };

    try bloom_commands.bf_mexists(&writer3, &store, &exists_args);

    // Should return array with 2 items: 1 (exists), 0 (doesn't exist)
    try testing.expectEqualStrings("*2\r\n:1\r\n:0\r\n", writer3.buffered());
}

test "BF.INFO command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Get info
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const args = [_]Value{
        .{ .data = "BF.INFO" },
        .{ .data = "bloom1" },
    };

    try bloom_commands.bf_info(&writer2, &store, &args);

    // Should return info array with key-value pairs
    // Format: *10\r\n$8\r\nCapacity\r\n:[number]\r\n$4\r\nSize\r\n:[number]\r\n...
    const result = writer2.buffered();
    try testing.expect(result.len > 0);
    try testing.expect(result[0] == '*'); // Starts with array
}

test "BF.INSERT command with new bloom filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "BF.INSERT" },
        .{ .data = "bloom1" },
        .{ .data = "ITEMS" },
        .{ .data = "item1" },
        .{ .data = "item2" },
    };

    try bloom_commands.bf_insert(&writer, &store, &args);

    // Should return array with results for each item
    const result = writer.buffered();
    try testing.expect(result.len > 0);
    try testing.expect(result[0] == '*'); // Starts with array

    // Verify the bloom filter was created and items were added
    const bf = try store.getBloomFilter("bloom1");
    try testing.expect(bf != null);
    try testing.expect(bf.?.check("item1"));
    try testing.expect(bf.?.check("item2"));
}

test "BF.INSERT command with existing bloom filter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // First reserve a bloom filter
    var buffer1: [4096]u8 = undefined;
    var writer1 = Writer.fixed(&buffer1);

    const reserve_args = [_]Value{
        .{ .data = "BF.RESERVE" },
        .{ .data = "bloom1" },
        .{ .data = "0.01" },
        .{ .data = "1000" },
    };

    try bloom_commands.bf_reserve(&writer1, &store, &reserve_args);

    // Insert items into existing bloom filter
    var buffer2: [4096]u8 = undefined;
    var writer2 = Writer.fixed(&buffer2);

    const args = [_]Value{
        .{ .data = "BF.INSERT" },
        .{ .data = "bloom1" },
        .{ .data = "ITEMS" },
        .{ .data = "item1" },
        .{ .data = "item2" },
    };

    try bloom_commands.bf_insert(&writer2, &store, &args);

    // Should return array with results for each item
    const result = writer2.buffered();
    try testing.expect(result.len > 0);
    try testing.expect(result[0] == '*'); // Starts with array
}
