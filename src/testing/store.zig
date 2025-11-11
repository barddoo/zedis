const std = @import("std");
const Store = @import("../store.zig").Store;
const ZedisObject = @import("../store.zig").ZedisObject;
const ZedisValue = @import("../store.zig").ZedisValue;
const ValueType = @import("../store.zig").ValueType;
const testing = std.testing;

test "Store init and deinit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.size());
}

test "Store set and get" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result = store.get("key1");
    try testing.expect(result != null);
    try testing.expectEqualStrings("hello", result.?.value.short_string.asSlice());
}

test "Store setInt and get" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.setInt("counter", 42);
    try testing.expectEqual(@as(u32, 1), store.size());

    const result = store.get("counter");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 42), result.?.value.int);
}

test "Store setObject with ZedisObject" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const obj = ZedisObject{ .value = .{ .string = try allocator.dupe(u8, "test") } };
    try store.putObject("key1", obj);

    const result = store.get("key1");
    try testing.expect(result != null);
    try testing.expectEqualStrings("test", result.?.value.string);
}

test "Store delete existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "value1");
    try testing.expectEqual(@as(u32, 1), store.size());
    try testing.expect(store.exists("key1"));

    const deleted = store.delete("key1");
    try testing.expect(deleted);
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(!store.exists("key1"));
}

test "Store delete non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const deleted = store.delete("nonexistent");
    try testing.expect(!deleted);
}

test "Store exists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try testing.expect(!store.exists("key1"));

    try store.set("key1", "value1");
    try testing.expect(store.exists("key1"));

    _ = store.delete("key1");
    try testing.expect(!store.exists("key1"));
}

test "Store getType" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try testing.expect(store.getType("nonexistent") == null);

    try store.set("str_key", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("str_key").?);

    try store.setInt("int_key", 42);
    try testing.expectEqual(ValueType.int, store.getType("int_key").?);
}

test "Store overwrite existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "original");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result1 = store.get("key1");
    try testing.expect(result1 != null);
    try testing.expectEqualStrings("original", result1.?.value.short_string.asSlice());

    try store.set("key1", "updated");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result2 = store.get("key1");
    try testing.expect(result2 != null);
    try testing.expectEqualStrings("updated", result2.?.value.short_string.asSlice());
}

test "Store overwrite string with integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);

    try store.setInt("key1", 123);
    try testing.expectEqual(ValueType.int, store.getType("key1").?);
    try testing.expectEqual(@as(i64, 123), store.get("key1").?.value.int);
}

test "Store overwrite integer with string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.setInt("key1", 456);
    try testing.expectEqual(ValueType.int, store.getType("key1").?);

    try store.set("key1", "world");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);
    try testing.expectEqualStrings("world", store.get("key1").?.value.short_string.asSlice());
}

test "Store expire functionality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "value1");
    try testing.expect(!store.isExpired("key1"));

    // Set expiration to far future
    const future_time = std.time.milliTimestamp() + 1000000;
    const success = try store.expire("key1", future_time);
    try testing.expect(success);
    try testing.expect(!store.isExpired("key1"));
    try testing.expect(store.get("key1") != null);
    try testing.expectEqual(future_time, store.getTtl("key1").?);

    // Set expiration to past
    const past_time: i64 = 12345;
    _ = try store.expire("key1", past_time);
    try testing.expect(store.isExpired("key1"));
    try testing.expect(store.get("key1") == null); // Should be deleted on get
}

test "Store expire non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const success = try store.expire("nonexistent", 12345);
    try testing.expect(!success);
}

test "Store delete removes from expiration map" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "value1");
    _ = try store.expire("key1", 12345);

    const deleted = store.delete("key1");
    try testing.expect(deleted);
    try testing.expect(!store.isExpired("key1"));
}

test "Store multiple keys with different types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.setInt("int1", 123);
    try store.setInt("int2", -456);

    try testing.expectEqual(@as(u32, 4), store.size());

    try testing.expectEqualStrings("hello", store.get("str1").?.value.short_string.asSlice());
    try testing.expectEqualStrings("world", store.get("str2").?.value.short_string.asSlice());
    try testing.expectEqual(@as(i64, 123), store.get("int1").?.value.int);
    try testing.expectEqual(@as(i64, -456), store.get("int2").?.value.int);
}

test "Store empty string values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("empty", "");

    const result = store.get("empty");
    try testing.expect(result != null);
    try testing.expectEqualStrings("", result.?.value.short_string.asSlice());
}

test "Store zero integer values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.setInt("zero", 0);

    const result = store.get("zero");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 0), result.?.value.int);
}

test "Store createList and getList" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try testing.expect(try store.getList("mylist") == null);

    const list = try store.createList("mylist");
    try testing.expectEqual(@as(usize, 0), list.len());

    const retrieved_list = try store.getList("mylist");
    try testing.expect(retrieved_list != null);
    try testing.expectEqual(@as(usize, 0), retrieved_list.?.len());
}

test "Store list append and insert operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const list = try store.createList("test_append_insert");

    try testing.expectEqual(@as(usize, 0), list.len());

    try list.append(.{ .string = try allocator.dupe(u8, "first") });
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("first", list.getByIndex(0).?.string);

    try list.append(.{ .string = try allocator.dupe(u8, "second") });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("second", list.getByIndex(1).?.string);

    try list.prepend(.{ .string = try allocator.dupe(u8, "zero") });
    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expectEqualStrings("zero", list.getByIndex(0).?.string);
    try testing.expectEqualStrings("first", list.getByIndex(1).?.string);
    try testing.expectEqualStrings("second", list.getByIndex(2).?.string);
}

test "Store list with mixed value types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const list = try store.createList("test_mixed_values");

    try list.append(.{ .string = try allocator.dupe(u8, "hello") });
    try list.append(.{ .int = 42 });
    try list.append(.{ .string = try allocator.dupe(u8, "world") });

    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expectEqualStrings("hello", list.getByIndex(0).?.string);
    try testing.expectEqual(@as(i64, 42), list.getByIndex(1).?.int);
    try testing.expectEqualStrings("world", list.getByIndex(2).?.string);
}

test "Store getList with wrong type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("notalist", "hello");

    const list = store.getList("notalist");
    try testing.expect(list == error.WrongType);
}

test "Store list type checking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    _ = try store.createList("mylist");
    try testing.expectEqual(ValueType.list, store.getType("mylist").?);
}

test "Store overwrite string with list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);

    _ = try store.createList("key1");
    try testing.expectEqual(ValueType.list, store.getType("key1").?);

    const list = try store.getList("key1");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 0), list.?.len());
}

test "Store overwrite list with string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const list = try store.createList("key1");
    try list.append(.{ .string = try allocator.dupe(u8, "item") });
    try testing.expectEqual(ValueType.list, store.getType("key1").?);

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);
    try testing.expectEqualStrings("hello", store.get("key1").?.value.short_string.asSlice());

    const retrieved_list = store.getList("key1");
    try testing.expect(retrieved_list == error.WrongType);
}

test "Store delete list key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const list = try store.createList("mylist");
    try list.append(.{ .string = try allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try allocator.dupe(u8, "item2") });

    try testing.expect(store.exists("mylist"));
    try testing.expectEqual(@as(u32, 1), store.size());

    const deleted = store.delete("mylist");
    try testing.expect(deleted);
    try testing.expect(!store.exists("mylist"));
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(try store.getList("mylist") == null);
}

test "Store empty list operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    const list = try store.createList("test_empty_ops");
    try testing.expectEqual(@as(usize, 0), list.len());

    try list.append(.{ .string = try allocator.dupe(u8, "") });
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("", list.getByIndex(0).?.string);

    try list.append(.{ .int = 0 });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqual(@as(i64, 0), list.getByIndex(1).?.int);
}

test "Store flush_db removes all keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    // Add various types of keys
    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.setInt("int1", 42);
    try store.setInt("int2", -100);

    const list = try store.createList("mylist");
    try list.append(.{ .string = try allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try allocator.dupe(u8, "item2") });

    // Verify all keys exist
    try testing.expectEqual(@as(u32, 5), store.size());
    try testing.expect(store.exists("str1"));
    try testing.expect(store.exists("str2"));
    try testing.expect(store.exists("int1"));
    try testing.expect(store.exists("int2"));
    try testing.expect(store.exists("mylist"));

    // Flush the database
    store.flush_db();

    // Verify all keys are removed
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(!store.exists("str1"));
    try testing.expect(!store.exists("str2"));
    try testing.expect(!store.exists("int1"));
    try testing.expect(!store.exists("int2"));
    try testing.expect(!store.exists("mylist"));

    // Verify getting keys returns null
    try testing.expect(store.get("str1") == null);
    try testing.expect(store.get("int1") == null);
    try testing.expect(try store.getList("mylist") == null);
}

test "Store flush_db on empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.size());

    // Flush empty store should not crash
    store.flush_db();

    try testing.expectEqual(@as(u32, 0), store.size());
}

test "Store flush_db allows reuse after flush" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    // Add keys
    try store.set("key1", "value1");
    try store.setInt("key2", 123);
    try testing.expectEqual(@as(u32, 2), store.size());

    // Flush
    store.flush_db();
    try testing.expectEqual(@as(u32, 0), store.size());

    // Add new keys after flush
    try store.set("key3", "value3");
    try store.setInt("key4", 456);
    try testing.expectEqual(@as(u32, 2), store.size());

    // Verify new keys work correctly
    try testing.expectEqualStrings("value3", store.get("key3").?.value.short_string.asSlice());
    try testing.expectEqual(@as(i64, 456), store.get("key4").?.value.int);

    // Verify old keys don't exist
    try testing.expect(store.get("key1") == null);
    try testing.expect(store.get("key2") == null);
}
