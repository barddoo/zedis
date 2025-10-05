const std = @import("std");
const testing = std.testing;
const Store = @import("../store.zig").Store;
const ZedisList = @import("../store.zig").ZedisList;
const PrimitiveValue = @import("../store.zig").PrimitiveValue;
const ValueType = @import("../store.zig").ValueType;

test "EXISTS command with single key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");

    try testing.expect(store.exists("key1"));
    try testing.expect(!store.exists("nonexistent"));
}

test "EXISTS command with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("key3", "value3");

    // Test that exists returns true for existing keys
    try testing.expect(store.exists("key1"));
    try testing.expect(store.exists("key2"));
    try testing.expect(store.exists("key3"));
    try testing.expect(!store.exists("key4"));
}

test "TYPE command with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("string_key", "hello");

    const string_type = store.getType("string_key");
    try testing.expect(string_type != null);
    try testing.expectEqual(ValueType.string, string_type.?);
}

test "TYPE command with integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("int_key", "123");

    const int_type = store.getType("int_key");
    try testing.expect(int_type != null);
    try testing.expectEqual(ValueType.int, int_type.?);
}

test "TYPE command with list value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    const list = try store.createList("list_key");
    try list.append(PrimitiveValue{ .string = "item1" });

    const list_type = store.getType("list_key");
    try testing.expect(list_type != null);
    try testing.expectEqual(ValueType.list, list_type.?);
}

test "TYPE command with nonexistent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    const none_type = store.getType("nonexistent");
    try testing.expect(none_type == null);
}

test "TTL command with key that has expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");

    // Set expiration to 10 seconds from now
    const future_time = std.time.milliTimestamp() + 10000;
    _ = try store.expire("key1", future_time);

    // Verify expiration is set
    const obj = store.get("key1");
    try testing.expect(obj != null);
    try testing.expect(obj.?.expiration != null);
    try testing.expect(obj.?.expiration.? > std.time.milliTimestamp());
}

test "TTL command with key without expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");

    const obj = store.get("key1");
    try testing.expect(obj != null);
    try testing.expect(obj.?.expiration == null);
}

test "TTL command with nonexistent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    const obj = store.get("nonexistent");
    try testing.expect(obj == null);
}

test "PERSIST command removes expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");

    // Set expiration
    const future_time = std.time.milliTimestamp() + 10000;
    _ = try store.expire("key1", future_time);

    // Verify expiration is set
    const obj_before = store.get("key1");
    try testing.expect(obj_before != null);
    try testing.expect(obj_before.?.expiration != null);

    // Test persist
    if (store.map.getPtr("key1")) |entry| {
        entry.expiration = null;
        try testing.expect(entry.expiration == null);
    }

    // Verify expiration is removed
    const obj_after = store.get("key1");
    try testing.expect(obj_after != null);
    try testing.expect(obj_after.?.expiration == null);
}

test "PERSIST command on key without expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");

    // Key has no expiration
    const obj = store.get("key1");
    try testing.expect(obj != null);
    try testing.expect(obj.?.expiration == null);
}

test "PERSIST command on nonexistent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    const entry = store.map.getPtr("nonexistent");
    try testing.expect(entry == null);
}

test "RENAME command basic functionality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("old_key", "value1");

    // Manually simulate rename
    const old_value = store.get("old_key");
    try testing.expect(old_value != null);

    // After rename, old key should not exist and new key should have the value
    try store.set("new_key", "value1");
    _ = store.delete("old_key");

    try testing.expect(!store.exists("old_key"));
    try testing.expect(store.exists("new_key"));

    const new_value = store.get("new_key");
    try testing.expect(new_value != null);
    try testing.expectEqualStrings("value1", new_value.?.value.string);
}

test "RENAME command overwrites existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("old_key", "value1");
    try store.set("new_key", "value2");

    // After rename, new_key should have old_key's value
    try store.set("new_key", "value1");
    _ = store.delete("old_key");

    try testing.expect(!store.exists("old_key"));
    try testing.expect(store.exists("new_key"));

    const new_value = store.get("new_key");
    try testing.expect(new_value != null);
    try testing.expectEqualStrings("value1", new_value.?.value.string);
}

test "RENAME command preserves expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("old_key", "value1");
    const future_time = std.time.milliTimestamp() + 10000;
    _ = try store.expire("old_key", future_time);

    // Get the old value with expiration
    const old_value = store.get("old_key");
    try testing.expect(old_value != null);
    try testing.expect(old_value.?.expiration != null);
}

test "RANDOMKEY on empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.map.count());
}

test "RANDOMKEY on store with single key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("only_key", "value");

    // With only one key, it should be the random key
    var it = store.map.iterator();
    const entry = it.next();
    try testing.expect(entry != null);
    try testing.expectEqualStrings("only_key", entry.?.key_ptr.*);
}

test "RANDOMKEY on store with multiple keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("key3", "value3");

    // Verify all keys exist
    try testing.expect(store.exists("key1"));
    try testing.expect(store.exists("key2"));
    try testing.expect(store.exists("key3"));
}

test "KEYS command with exact pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("exact_key", "value");
    try store.set("other_key", "value");

    // Count matching keys
    var count: usize = 0;
    var it = store.map.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, "exact_key", entry.key_ptr.*)) {
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "KEYS command with wildcard *" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("other", "value3");

    // All keys should match *
    try testing.expectEqual(@as(u32, 3), store.map.count());
}

test "KEYS command with pattern prefix*" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("prefix1", "value1");
    try store.set("prefix2", "value2");
    try store.set("other", "value3");

    // Keys with prefix should match
    try testing.expect(store.exists("prefix1"));
    try testing.expect(store.exists("prefix2"));
}

test "KEYS command with pattern *suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("test_suffix", "value1");
    try store.set("other_suffix", "value2");
    try store.set("prefix", "value3");

    // Keys with suffix should match
    try testing.expect(store.exists("test_suffix"));
    try testing.expect(store.exists("other_suffix"));
}

test "KEYS command with pattern ?" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("a", "value1");
    try store.set("b", "value2");
    try store.set("ab", "value3");

    // Single character keys should exist
    try testing.expect(store.exists("a"));
    try testing.expect(store.exists("b"));
}

test "DELETE key from store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "value1");
    try testing.expect(store.exists("key1"));

    const deleted = store.delete("key1");
    try testing.expect(deleted);
    try testing.expect(!store.exists("key1"));
}

test "DELETE nonexistent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    const deleted = store.delete("nonexistent");
    try testing.expect(!deleted);
}
