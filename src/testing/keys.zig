const std = @import("std");
const Store = @import("../store.zig").Store;
const Value = @import("../parser.zig").Value;
const testing = std.testing;
const keys_commands = @import("../commands/keys.zig");

test "EXISTS command with existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const args = [_]Value{
        .{ .data = "EXISTS" },
        .{ .data = "mykey" },
    };

    try keys_commands.exists(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());
}

test "EXISTS command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "EXISTS" },
        .{ .data = "nonexistent" },
    };

    try keys_commands.exists(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "KEYS command with wildcard pattern" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("user:1", "alice");
    try store.set("user:2", "bob");
    try store.set("post:1", "hello");

    const args = [_]Value{
        .{ .data = "KEYS" },
        .{ .data = "*" },
    };

    try keys_commands.keys(&writer, &store, &args);

    const output = writer.buffered();
    // Should return array of 3 keys
    try testing.expect(std.mem.startsWith(u8, output, "*3\r\n"));
}

test "KEYS command with empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "KEYS" },
        .{ .data = "*" },
    };

    try keys_commands.keys(&writer, &store, &args);

    try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "TTL command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "TTL" },
        .{ .data = "nonexistent" },
    };

    try keys_commands.ttl(&writer, &store, &args);

    try testing.expectEqualStrings(":-2\r\n", writer.buffered());
}

test "TTL command with key without expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const args = [_]Value{
        .{ .data = "TTL" },
        .{ .data = "mykey" },
    };

    try keys_commands.ttl(&writer, &store, &args);

    try testing.expectEqualStrings(":-1\r\n", writer.buffered());
}

test "TTL command with key with expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "value");
    const future_time = std.time.milliTimestamp() + 10000; // 10 seconds in future
    _ = try store.expire("mykey", future_time);

    const args = [_]Value{
        .{ .data = "TTL" },
        .{ .data = "mykey" },
    };

    try keys_commands.ttl(&writer, &store, &args);

    const output = writer.buffered();
    // Should return the expiration timestamp
    try testing.expect(std.mem.startsWith(u8, output, ":"));
}

test "PERSIST command with key having expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "value");
    const future_time = std.time.milliTimestamp() + 10000;
    _ = try store.expire("mykey", future_time);

    const args = [_]Value{
        .{ .data = "PERSIST" },
        .{ .data = "mykey" },
    };

    try keys_commands.persist(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    // Verify expiration was removed
    const ttl = store.getTtl("mykey");
    try testing.expect(ttl == null);
}

test "PERSIST command with key without expiration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "value");

    const args = [_]Value{
        .{ .data = "PERSIST" },
        .{ .data = "mykey" },
    };

    try keys_commands.persist(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "TYPE command with string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("mykey", "hello");

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mykey" },
    };

    try keys_commands.typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$6\r\nstring\r\n", writer.buffered());
}

test "TYPE command with integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.setInt("mykey", 42);

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mykey" },
    };

    try keys_commands.typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$6\r\nstring\r\n", writer.buffered());
}

test "TYPE command with list value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    _ = try store.createList("mylist");

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "mylist" },
    };

    try keys_commands.typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$4\r\nlist\r\n", writer.buffered());
}

test "TYPE command with non-existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "TYPE" },
        .{ .data = "nonexistent" },
    };

    try keys_commands.typeCmd(&writer, &store, &args);

    try testing.expectEqualStrings("$4\r\nnone\r\n", writer.buffered());
}

test "RENAME command with existing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("oldkey", "value");

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "oldkey" },
        .{ .data = "newkey" },
    };

    try keys_commands.rename(&writer, &store, &args);

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

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "nonexistent" },
        .{ .data = "newkey" },
    };

    const result = keys_commands.rename(&writer, &store, &args);
    try testing.expectError(error.KeyNotFound, result);
}

test "RANDOMKEY command with non-empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("key3", "value3");

    const args = [_]Value{
        .{ .data = "RANDOMKEY" },
    };

    try keys_commands.randomkey(&writer, &store, &args);

    const output = writer.buffered();
    // Should return a bulk string (key)
    try testing.expect(std.mem.startsWith(u8, output, "$"));
    // Should not be null
    try testing.expect(!std.mem.eql(u8, output, "$-1\r\n"));
}

test "RANDOMKEY command with empty store" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "RANDOMKEY" },
    };

    try keys_commands.randomkey(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "KEYS command returns all keys when pattern is wildcard" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("apple", "fruit");
    try store.set("banana", "fruit");
    try store.setInt("count", 42);

    const args = [_]Value{
        .{ .data = "KEYS" },
        .{ .data = "*" },
    };

    try keys_commands.keys(&writer, &store, &args);

    const output = writer.buffered();
    // Should return array with 3 elements
    try testing.expect(std.mem.startsWith(u8, output, "*3\r\n"));
    // Verify all keys are present in output
    try testing.expect(std.mem.indexOf(u8, output, "apple") != null);
    try testing.expect(std.mem.indexOf(u8, output, "banana") != null);
    try testing.expect(std.mem.indexOf(u8, output, "count") != null);
}

test "RENAME overwrites existing destination key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator, 4096);
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try store.set("source", "source_value");
    try store.set("dest", "dest_value");

    const args = [_]Value{
        .{ .data = "RENAME" },
        .{ .data = "source" },
        .{ .data = "dest" },
    };

    try keys_commands.rename(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    // Verify source is gone
    try testing.expect(store.get("source") == null);

    // Verify dest has source's value
    const dest_value = store.get("dest");
    try testing.expect(dest_value != null);
    try testing.expectEqualStrings("source_value", dest_value.?.value.short_string.asSlice());
}
