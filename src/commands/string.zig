const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");
const Io = std.Io;

pub fn set(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const value = args[2].asSlice();

    try store.set(key, value);

    try resp.writeOK(writer);
}

pub fn get(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const value = store.get(key);

    if (value) |v| {
        switch (v.value) {
            .string => |s| try resp.writeBulkString(writer, s),
            .short_string => |ss| try resp.writeBulkString(writer, ss.asSlice()),
            .int => |i| {
                try resp.writeIntBulkString(writer, i);
            },
            .list, .time_series => return error.WrongType,
        }
    } else {
        try resp.writeNull(writer);
    }
}

pub fn incr(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const new_value = try incrDecr(store, key, 1);

    try resp.writeIntBulkString(writer, new_value);
}

pub fn decr(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const new_value = try incrDecr(store, key, -1);

    try resp.writeIntBulkString(writer, new_value);
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
            .short_string => |_| {
                const intValue = std.fmt.parseInt(i64, v.value.short_string.asSlice(), 10) catch {
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
            else => return error.WrongType,
        }

        const int_object = ZedisObject{ .value = .{ .int = new_value } };
        try store_ptr.putObject(key, int_object);

        return new_value;
    } else {
        // Redis behavior: non-existent key is treated as 0, then the operation is applied
        const new_value = std.math.add(i64, 0, value) catch {
            return error.ValueNotInteger;
        };
        try store_ptr.setInt(key, new_value);
        return new_value;
    }
}

pub fn del(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    var deleted: u32 = 0;
    for (args[1..]) |key| {
        if (store.delete(key.asSlice())) {
            deleted += 1;
        }
    }

    try resp.writeInt(writer, deleted);
}

pub fn expire(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const expiration_seconds = args[2].asInt() catch {
        return resp.writeInt(writer, 0);
    };

    const result = if (expiration_seconds < 0)
        store.delete(key)
    else blk: {
        const ts = try Io.Clock.real.now(store.io);
        const current_time = ts.toMilliseconds();

        break :blk store.expire(key, current_time + (expiration_seconds * 1000));
    };

    try resp.writeInt(writer, @intFromBool(try result));
}

pub fn expireAt(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const ts = try Io.Clock.real.now(store.io);
    const current_time = ts.toMilliseconds();
    const expiration_timestamp = args[2].asInt() catch {
        return resp.writeInt(writer, 0);
    };

    const result = if (expiration_timestamp <= current_time)
        store.delete(key)
    else
        store.expire(key, expiration_timestamp) catch false;

    try resp.writeInt(writer, @intFromBool(result));
}

pub fn append(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const append_value = args[2].asSlice();

    const current_value = store.get(key);
    var new_value: []const u8 = undefined;
    var needs_free = false;

    if (current_value) |v| {
        const current_str = switch (v.value) {
            .string => |s| s,
            .short_string => |ss| ss.asSlice(),
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

    try resp.writeInt(writer, new_value.len);
}

pub fn strlen(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
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
        try resp.writeInt(writer, len);
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn getset(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const new_value = args[2].asSlice();

    // Get old value
    const old_value = store.get(key);

    if (old_value) |v| {
        switch (v.value) {
            .string => |s| try resp.writeBulkString(writer, s),
            .short_string => |ss| try resp.writeBulkString(writer, ss.asSlice()),
            .int => |i| try resp.writeIntBulkString(writer, i),
            else => return error.WrongType,
        }
    } else {
        try resp.writeNull(writer);
    }

    // Set new value
    try store.set(key, new_value);
}

pub fn mget(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    // Write array header
    try resp.writeListLen(writer, args.len - 1);

    // Get each key
    for (args[1..]) |key_arg| {
        const key = key_arg.asSlice();
        const value = store.get(key);

        if (value) |v| {
            switch (v.value) {
                .string => |s| try resp.writeBulkString(writer, s),
                .short_string => |ss| try resp.writeBulkString(writer, ss.asSlice()),
                .int => |i| try resp.writeIntBulkString(writer, i),
                else => try resp.writeNull(writer), // Lists return null
            }
        } else {
            try resp.writeNull(writer);
        }
    }
}

pub fn mset(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    // Args format: MSET key1 value1 key2 value2 ...
    if (args.len % 2 != 1) {
        return error.InvalidArgument;
    }

    // Set all key-value pairs
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const key = args[i].asSlice();
        const value = args[i + 1].asSlice();
        try store.set(key, value);
    }

    try resp.writeOK(writer);
}

pub fn setex(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const seconds = args[2].asInt() catch {
        return error.ValueNotInteger;
    };
    const value = args[3].asSlice();

    // Set the value
    try store.set(key, value);

    // Set expiration
    if (seconds > 0) {
        const ts = try Io.Clock.real.now(store.io);
        const now = ts.toMilliseconds();
        const expiration_time = now + (seconds * 1000);
        _ = try store.expire(key, expiration_time);
    }

    try resp.writeOK(writer);
}

pub fn setnx(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const value = args[2].asSlice();

    const exists = store.get(key) != null;

    if (!exists) {
        try store.set(key, value);
        try resp.writeInt(writer, 1);
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn incrby(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const increment = args[2].asInt() catch {
        return error.ValueNotInteger;
    };

    const new_value = try incrDecr(store, key, increment);
    try resp.writeIntBulkString(writer, new_value);
}

pub fn decrby(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const decrement = args[2].asInt() catch {
        return error.ValueNotInteger;
    };

    const new_value = try incrDecr(store, key, -decrement);
    try resp.writeIntBulkString(writer, new_value);
}

pub fn incrbyfloat(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const increment_str = args[2].asSlice();

    // Parse increment as float
    const increment = std.fmt.parseFloat(f64, increment_str) catch {
        return error.InvalidFloat;
    };

    // Get current value
    const current_value = store.map.get(key);
    var current_float: f64 = 0.0;

    if (current_value) |v| {
        switch (v.value) {
            .string => |s| {
                current_float = std.fmt.parseFloat(f64, s) catch {
                    return error.InvalidFloat;
                };
            },
            .short_string => |ss| {
                current_float = std.fmt.parseFloat(f64, ss.asSlice()) catch {
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
    try resp.writeBulkString(writer, result);
}
