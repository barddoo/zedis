const std = @import("std");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const PrimitiveValue = @import("../store.zig").PrimitiveValue;
const ZedisListNode = @import("../list.zig").ZedisListNode;
const ZedisList = @import("../list.zig").ZedisList;
const Store = @import("../store.zig").Store;
const resp = @import("./resp.zig");
const Io = std.Io;
const testing = std.testing;
const Writer = Io.Writer;
const Clock = @import("../clock.zig");

/// Helper function to normalize a list index (handles negative indices).
/// Returns null if the index is out of bounds.
inline fn normalizeListIndex(index: i64, list_len: usize) ?usize {
    return ZedisList.normalizeIndex(index, list_len);
}

/// Helper function to normalize a range index with clamping behavior.
/// Used by LRANGE which clamps out-of-bounds indices instead of returning errors.
/// Returns null only when the start index is beyond the list length (should return empty list).
inline fn normalizeRangeIndex(index: i64, list_len: usize, comptime is_start: bool) ?usize {
    if (index < 0) {
        const neg_offset = @as(usize, @intCast(-index));
        if (neg_offset > list_len) {
            return 0; // Clamp to start
        }
        return list_len - neg_offset;
    } else {
        const pos_index = @as(usize, @intCast(index));
        if (is_start) {
            // For start index: if beyond list, signal empty range
            if (pos_index >= list_len) return null;
        } else {
            // For stop index: clamp to last element
            if (pos_index >= list_len) return list_len - 1;
        }
        return pos_index;
    }
}

pub fn lpush(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const list = try store.getSetList(key);

    for (args[2..]) |arg| {
        const pv = try PrimitiveValue.fromSlice(arg.asSlice(), store.allocator);
        try list.prepend(pv);
    }

    try resp.writeInt(writer, list.len());
}

pub fn rpush(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const list = try store.getSetList(key);

    for (args[2..]) |arg| {
        const pv = try PrimitiveValue.fromSlice(arg.asSlice(), store.allocator);
        try list.append(pv);
    }

    try resp.writeInt(writer, list.len());
}

pub fn lpop(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const list = try store.getList(key) orelse {
        try resp.writeNull(writer);
        return;
    };

    var count: usize = 1;

    if (args.len == 3) {
        count = try args[2].asUsize();
    }

    const list_len = list.len();
    const actual_count = @min(count, list_len);

    if (actual_count == 0) {
        try resp.writeNull(writer);
        return;
    }

    if (actual_count == 1) {
        const item = list.popFirst().?;
        try resp.writePrimitiveValue(writer, item);
        return;
    }
    if (actual_count > 1) {
        try resp.writeListLen(writer, actual_count);
        for (0..actual_count) |_| {
            const item = list.popFirst().?;
            try resp.writePrimitiveValue(writer, item);
        }
        return;
    }
}

pub fn rpop(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const list = try store.getList(key) orelse {
        try resp.writeNull(writer);
        return;
    };

    var count: usize = 1;

    if (args.len == 3) {
        count = try args[2].asUsize();
    }

    const list_len = list.len();
    const actual_count = @min(count, list_len);

    if (actual_count == 0) {
        try resp.writeNull(writer);
        return;
    }

    if (actual_count == 1) {
        const item = list.pop().?;
        try resp.writePrimitiveValue(writer, item);
        return;
    }
    if (actual_count > 1) {
        try resp.writeListLen(writer, actual_count);
        for (0..actual_count) |_| {
            const item = list.pop().?;
            try resp.writePrimitiveValue(writer, item);
        }
        return;
    }
}

pub fn llen(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const list = try store.getList(key);

    if (list) |l| {
        try resp.writeInt(writer, l.len());
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn lindex(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const index = try args[2].asInt();
    const list = try store.getList(key) orelse {
        try resp.writeNull(writer);
        return;
    };

    const actual_index = normalizeListIndex(index, list.len()) orelse {
        try resp.writeNull(writer);
        return;
    };

    const item = list.getByIndex(actual_index) orelse {
        try resp.writeNull(writer);
        return;
    };

    try resp.writePrimitiveValue(writer, item);
}

pub fn lset(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const index = try args[2].asInt();
    const value = args[3].asSlice();

    const list = try store.getList(key) orelse {
        return error.NoSuchKey;
    };

    const actual_index = normalizeListIndex(index, list.len()) orelse {
        return error.KeyNotFound;
    };

    // Set value inline if small enough, otherwise duplicate via KV allocator
    const pv = try PrimitiveValue.fromSlice(value, store.allocator);
    try list.setByIndex(actual_index, pv);

    try resp.writeOK(writer);
}

pub fn lrange(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const start = try args[2].asInt();
    const stop = try args[3].asInt();

    const list = try store.getList(key) orelse {
        try resp.writeListLen(writer, 0);
        return;
    };

    const list_len = list.len();
    if (list_len == 0) {
        try resp.writeListLen(writer, 0);
        return;
    }

    // Normalize indices with clamping behavior
    const actual_start = normalizeRangeIndex(start, list_len, true) orelse {
        try resp.writeListLen(writer, 0);
        return;
    };

    const actual_stop = normalizeRangeIndex(stop, list_len, false) orelse {
        try resp.writeListLen(writer, 0);
        return;
    };

    // Handle invalid range
    if (actual_start > actual_stop) {
        try resp.writeListLen(writer, 0);
        return;
    }

    const count = actual_stop - actual_start + 1;
    try resp.writeListLen(writer, count);

    // Stream items directly without intermediate allocation
    var current = list.list.first;
    var i: usize = 0;
    while (current) |node| : (i += 1) {
        if (i >= actual_start and i <= actual_stop) {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            try resp.writePrimitiveValue(writer, list_node.data);
        }
        if (i > actual_stop) break;
        current = node.next;
    }
}

// LPUSH Tests
test "LPUSH single element to new list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "world" },
    };

    try lpush(&writer, &store, &args);

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

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "three" },
        .{ .data = "two" },
        .{ .data = "one" },
    };

    try lpush(&writer, &store, &args);

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

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // First, add some elements
    const args1 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "initial" },
    };
    try lpush(&writer, &store, &args1);
    writer = Writer.fixed(&buffer);

    // Then add more elements
    const args2 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "second" },
        .{ .data = "first" },
    };
    try lpush(&writer, &store, &args2);

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

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };

    try rpush(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const list = try store.getList("mylist");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 1), list.?.len());
}

test "RPUSH multiple elements to new list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };

    try rpush(&writer, &store, &args);

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

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // First create a list with one element
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Then pop the element
    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try lpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());

    // List should be empty now
    const list = try store.getList("mylist");
    try testing.expect(list == null or list.?.len() == 0);
}

test "LPOP from non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "nonexistent" },
    };

    try lpop(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LPOP with count from list with multiple elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create a list with multiple elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "three" },
        .{ .data = "two" },
        .{ .data = "one" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Pop 2 elements
    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
        .{ .data = "2" },
    };
    try lpop(&writer, &store, &pop_args);

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

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create a list with elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Pop 0 elements
    const pop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
        .{ .data = "0" },
    };
    try lpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

// RPOP Tests
test "RPOP from list with single element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // First create a list with one element
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "hello" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Then pop the element
    const pop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
    };
    try rpop(&writer, &store, &pop_args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());
}

test "RPOP with count from list with multiple elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create a list with multiple elements
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Pop 2 elements from the right
    const pop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
        .{ .data = "2" },
    };
    try rpop(&writer, &store, &pop_args);

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

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create a list with elements
    const push_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try lpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Check length
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "LLEN on non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "nonexistent" },
    };

    try llen(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "Mixed LPUSH and RPUSH operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // LPUSH "middle"
    const lpush_args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "middle" },
    };
    try lpush(&writer, &store, &lpush_args);
    writer = Writer.fixed(&buffer);

    // LPUSH "left"
    const lpush_args2 = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = "mylist" },
        .{ .data = "left" },
    };
    try lpush(&writer, &store, &lpush_args2);
    writer = Writer.fixed(&buffer);

    // RPUSH "right"
    const rpush_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "right" },
    };
    try rpush(&writer, &store, &rpush_args);
    writer = Writer.fixed(&buffer);

    // Should have 3 elements in order: left, middle, right
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try llen(&writer, &store, &llen_args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());
}

test "LPOP and RPOP from the same list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // LPOP should get "one"
    const lpop_args = [_]Value{
        .{ .data = "LPOP" },
        .{ .data = "mylist" },
    };
    try lpop(&writer, &store, &lpop_args);
    try testing.expectEqualStrings("$3\r\none\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // RPOP should get "three"
    const rpop_args = [_]Value{
        .{ .data = "RPOP" },
        .{ .data = "mylist" },
    };
    try rpop(&writer, &store, &rpop_args);
    try testing.expectEqualStrings("$5\r\nthree\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // Should have 1 element left ("two")
    const llen_args = [_]Value{
        .{ .data = "LLEN" },
        .{ .data = "mylist" },
    };
    try llen(&writer, &store, &llen_args);
    try testing.expectEqualStrings(":1\r\n", writer.buffered());
}

// LINDEX Tests
test "LINDEX get first element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Get first element (index 0)
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "0" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$3\r\none\r\n", writer.buffered());
}

test "LINDEX get last element with negative index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Get last element (index -1)
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$5\r\nthree\r\n", writer.buffered());
}

test "LINDEX with out of range index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Try to get element at index 10
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "10" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "LINDEX on non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
    };

    try lindex(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

// LSET Tests
test "LSET update element at index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Set element at index 1 to "TWO"
    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "1" },
        .{ .data = "TWO" },
    };
    try lset(&writer, &store, &lset_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // Verify the element was updated
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "1" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$3\r\nTWO\r\n", writer.buffered());
}

test "LSET with negative index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Set last element using -1
    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
        .{ .data = "THREE" },
    };
    try lset(&writer, &store, &lset_args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    writer = Writer.fixed(&buffer);

    // Verify the last element was updated
    const lindex_args = [_]Value{
        .{ .data = "LINDEX" },
        .{ .data = "mylist" },
        .{ .data = "-1" },
    };
    try lindex(&writer, &store, &lindex_args);

    try testing.expectEqualStrings("$5\r\nTHREE\r\n", writer.buffered());
}

test "LSET on non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
        .{ .data = "value" },
    };

    const result = lset(&writer, &store, &args);
    try testing.expectError(error.NoSuchKey, result);
}

test "LSET with out of range index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Try to set element at index 10
    const lset_args = [_]Value{
        .{ .data = "LSET" },
        .{ .data = "mylist" },
        .{ .data = "10" },
        .{ .data = "value" },
    };

    const result = lset(&writer, &store, &lset_args);
    try testing.expectError(error.KeyNotFound, result);
}

// LRANGE Tests
test "LRANGE get all elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Get all elements (0 to -1)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "0" },
        .{ .data = "-1" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*3\r\n$3\r\none\r\n$3\r\ntwo\r\n$5\r\nthree\r\n", writer.buffered());
}

test "LRANGE get subset of elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

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
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Get elements from index 1 to 3
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "1" },
        .{ .data = "3" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*3\r\n$3\r\ntwo\r\n$5\r\nthree\r\n$4\r\nfour\r\n", writer.buffered());
}

test "LRANGE with negative indices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

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
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Get last 2 elements (-2 to -1)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "-2" },
        .{ .data = "-1" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*2\r\n$4\r\nfour\r\n$4\r\nfive\r\n", writer.buffered());
}

test "LRANGE on non-existing list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "nonexistent" },
        .{ .data = "0" },
        .{ .data = "-1" },
    };

    try lrange(&writer, &store, &args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LRANGE with out of range indices" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Try to get elements from 10 to 20 (out of range)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "10" },
        .{ .data = "20" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "LRANGE with reversed range" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    // Create list with: one, two, three
    const push_args = [_]Value{
        .{ .data = "RPUSH" },
        .{ .data = "mylist" },
        .{ .data = "one" },
        .{ .data = "two" },
        .{ .data = "three" },
    };
    try rpush(&writer, &store, &push_args);
    writer = Writer.fixed(&buffer);

    // Try reversed range (start > stop)
    const lrange_args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = "mylist" },
        .{ .data = "2" },
        .{ .data = "1" },
    };
    try lrange(&writer, &store, &lrange_args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}
