const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;

pub fn set(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const value = args[2].asSlice();

    try client.store.set(key, value);

    try client.writeBulkString("OK");
}

pub fn get(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const value = client.store.get(key);

    if (value) |v| {
        switch (v.value) {
            .string => |s| try client.writeBulkString(s),
            .int => |i| {
                const int_str = try std.fmt.allocPrint(client.allocator, "{d}", .{i});
                defer client.allocator.free(int_str);
                try client.writeBulkString(int_str);
            },
            .list => |*list| {
                var current = list.list.first;
                while (current) |node| {
                    const list_node: *const @import("../store.zig").ZedisListNode = @fieldParentPtr("node", node);
                    const entry = list_node.data;

                    switch (entry) {
                        .string => |str| try client.writeBulkString(str),
                        .int => |i| {
                            const int_str = try std.fmt.allocPrint(client.allocator, "{d}", .{i});
                            defer client.allocator.free(int_str);
                            try client.writeBulkString(int_str);
                        },
                    }

                    current = node.next;
                }
            },
        }
    } else {
        try client.writeNull();
    }
}

pub fn incr(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const new_value = incrDecr(client.store, key, 1) catch |err| switch (err) {
        error.KeyNotFound => {
            // For INCR on non-existent key, Redis creates it with value 0 then increments
            try client.store.set(key, "1");
            try client.writeBulkString("1");
            return;
        },
        else => return err,
    };

    const result_str = try std.fmt.allocPrint(client.allocator, "{d}", .{new_value});
    defer client.allocator.free(result_str);
    try client.writeBulkString(result_str);
}

pub fn decr(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const new_value = incrDecr(client.store, key, -1) catch |err| switch (err) {
        error.WrongType => {
            return client.writeError("ERR value is not an integer or out of range", .{});
        },
        error.ValueNotInteger => {
            return client.writeError("ERR value is not an integer or out of range", .{});
        },
        error.KeyNotFound => {
            // For DECR on non-existent key, Redis creates it with value 0 then decrements
            try client.store.set(key, "-1");
            try client.writeBulkString("-1");
            return;
        },
        else => return err,
    };

    const result_str = try std.fmt.allocPrint(client.allocator, "{d}", .{new_value});
    defer client.allocator.free(result_str);
    try client.writeBulkString(result_str);
}

fn incrDecr(store_ptr: *Store, key: []const u8, value: i64) !i64 {
    const current_value = store_ptr.map.get(key);
    if (current_value) |v| {
        var new_value: i64 = undefined;

        switch (v.value) {
            .string => |_| {
                const intValue = std.fmt.parseInt(i64, v.value.string, 10) catch {
                    return error.ValueNotInteger;
                };
                new_value = std.math.add(i64, intValue, value) catch {
                    return error.ValueNotInteger;
                };
            },
            .int => |_| {
                new_value = std.math.add(i64, v.value.int, value) catch {
                    return error.ValueNotInteger;
                };
            },
            else => return error.ValueNotInteger,
        }

        var buf: [20]u8 = undefined;
        const int_str = try std.fmt.bufPrint(&buf, "{d}", .{new_value});
        try store_ptr.set(key, int_str);

        return new_value;
    } else {
        return error.KeyNotFound;
    }
}

pub fn del(client: *Client, args: []const Value) !void {
    var deleted: usize = 0;
    for (args[1..]) |key| {
        if (client.store.delete(key.asSlice())) {
            deleted += 1;
        }
    }

    try client.writeInt(deleted);
}

pub fn expire(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const expiration_seconds = args[2].asInt() catch {
        return client.writeInt(0);
    };

    const result = if (expiration_seconds < 0)
        client.store.delete(key)
    else
        client.store.expire(key, std.time.milliTimestamp() + (expiration_seconds * 1000)) catch false;

    try client.writeInt(@as(usize, if (result) 1 else 0));
}

pub fn append(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const append_value = args[2].asSlice();

    const existing_value = client.store.get(key);
    var new_value: []u8 = undefined;

    if (existing_value) |v| {
        switch (v.value) {
            .string => |s| {
                const combined_len = s.len + append_value.len;
                new_value = try client.allocator.alloc(u8, combined_len);
                @memcpy(new_value[0..s.len], s);
                @memcpy(new_value[s.len..], append_value);
            },
            .int => |i| {
                const int_str = try std.fmt.allocPrint(client.allocator, "{d}", .{i});
                defer client.allocator.free(int_str);

                const combined_len = int_str.len + append_value.len;
                new_value = try client.allocator.alloc(u8, combined_len);
                @memcpy(new_value[0..int_str.len], int_str);
                @memcpy(new_value[int_str.len..], append_value);
            },
            else => return error.WrongType,
        }
    } else {
        new_value = @constCast(append_value);
    }

    try client.store.set(key, new_value);

    // Return the length of the new string
    try client.writeInt(new_value.len);

    if (existing_value) |v| {
        if (v.value == .string or v.value == .int) {
            client.allocator.free(new_value);
        }
    }
}

pub fn strlen(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();

    const value = client.store.get(key);

    if (value) |v| {
        switch (v.value) {
            .string => |str| {
                try client.writeInt(str.len);
            },
            .int => |i| {
                const len = std.fmt.count("{}", .{i});
                try client.writeInt(len);
            },
            else => return error.WrongType,
        }
    } else {
        try client.writeInt(0);
    }
}

pub fn getset(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const new_value = args[2].asSlice();

    // Get old value first
    const old_value = client.store.get(key);

    // Set new value (parse as int if possible, otherwise string)
    try client.store.set(key, new_value);

    // Return old value
    if (old_value) |v| {
        switch (v.value) {
            .string => |s| try client.writeBulkString(s),
            .int => |i| {
                try client.writeIntAsString(i);
            },
            else => return error.WrongType,
        }
    } else {
        try client.writeNull();
    }
}

pub fn mget(client: *Client, args: []const Value) !void {
    const num_keys = args.len - 1;
    try client.writeListLen(num_keys);

    for (args[1..]) |key_arg| {
        const key = key_arg.asSlice();
        const value = client.store.get(key);

        if (value) |v| {
            switch (v.value) {
                .string => |s| try client.writeBulkString(s),
                .int => |i| try client.writeIntAsString(i),
                .list => return error.WrongType,
            }
        } else {
            try client.writeNull();
        }
    }
}

pub fn mset(client: *Client, args: []const Value) !void {
    for (0..args.len / 2) |i| {
        const key = args[i * 2 + 1].asSlice();
        const value = args[i * 2 + 2].asSlice();
        try client.store.set(key, value);
    }
    try client.writeBulkString("OK");
}

pub fn setex(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const seconds = args[2].asInt() catch {
        return client.writeError("ERR value is not an integer or out of range", .{});
    };
    const value = args[3].asSlice();

    if (seconds <= 0) {
        return client.writeError("ERR invalid expire time in SETEX", .{});
    }

    try client.store.set(key, value);
    const expiration_time = std.time.milliTimestamp() + (seconds * 1000);
    _ = try client.store.expire(key, expiration_time);

    try client.writeBulkString("OK");
}

pub fn setnx(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const value = args[2].asSlice();

    const existing = client.store.get(key);
    if (existing == null) {
        try client.store.set(key, value);
        try client.writeInt(1);
    } else {
        try client.writeInt(0);
    }
}

pub fn incrby(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const increment = args[2].asInt() catch {
        return client.writeError("ERR value is not an integer or out of range", .{});
    };

    const new_value = incrDecr(client.store, key, increment) catch |err| switch (err) {
        error.KeyNotFound => {
            const value = increment;
            var buf: [20]u8 = undefined;
            const int_str = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try client.store.set(key, int_str);
            try client.writeIntAsString(value);
            return;
        },
        error.ValueNotInteger => {
            return client.writeError("ERR value is not an integer or out of range", .{});
        },
        else => return err,
    };

    try client.writeIntAsString(new_value);
}

pub fn decrby(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const decrement = args[2].asInt() catch {
        return client.writeError("ERR value is not an integer or out of range", .{});
    };

    const new_value = incrDecr(client.store, key, -decrement) catch |err| switch (err) {
        error.KeyNotFound => {
            const value = -decrement;
            var buf: [20]u8 = undefined;
            const int_str = try std.fmt.bufPrint(&buf, "{d}", .{value});
            try client.store.set(key, int_str);
            try client.writeIntAsString(value);
            return;
        },
        error.ValueNotInteger => {
            return client.writeError("ERR value is not an integer or out of range", .{});
        },
        else => return err,
    };

    try client.writeIntAsString(new_value);
}

pub fn incrbyfloat(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const increment_str = args[2].asSlice();

    const increment = std.fmt.parseFloat(f64, increment_str) catch {
        return client.writeError("ERR value is not a valid float", .{});
    };

    const current_value = client.store.get(key);
    var new_value: f64 = undefined;

    if (current_value) |v| {
        switch (v.value) {
            .string => |s| {
                const float_val = std.fmt.parseFloat(f64, s) catch {
                    return client.writeError("ERR value is not a valid float", .{});
                };
                new_value = float_val + increment;
            },
            .int => |i| {
                const float_val: f64 = @floatFromInt(i);
                new_value = float_val + increment;
            },
            else => return error.WrongType,
        }
    } else {
        new_value = increment;
    }

    // Format the result as a string
    const result_str = try std.fmt.allocPrint(client.allocator, "{d}", .{new_value});
    defer client.allocator.free(result_str);

    try client.store.set(key, result_str);
    try client.writeBulkString(result_str);
}

const testing = std.testing;

test "incrDecr helper function with string integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    try store.set("key1", "100");

    const result = try incrDecr(&store, "key1", 50);
    try testing.expectEqual(@as(i64, 150), result);

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 150), stored_value.?.value.int);
}

test "incrDecr helper function with integer overflow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    var buf: [20]u8 = undefined;
    const max_int_str = try std.fmt.bufPrint(&buf, "{d}", .{std.math.maxInt(i64)});
    try store.set("key1", max_int_str);

    const result = incrDecr(&store, "key1", 1);
    try testing.expectError(error.ValueNotInteger, result);
}

test "incrDecr helper function with non-existent key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = Store.init(allocator);
    defer store.deinit();

    const result = incrDecr(&store, "nonexistent", 1);
    try testing.expectError(error.KeyNotFound, result);
}
