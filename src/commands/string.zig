const std = @import("std");
const storeModule = @import("../storage/store.zig");
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");
const Io = std.Io;
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Writer = Io.Writer;
const testing = std.testing;
const Clock = @import("../app/clock.zig");

pub fn set(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = args[2].as_slice();

    try store.set(key, value);

    try resp.write_ok(writer);
}

pub fn get(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = store.get(key);

    if (value) |v| {
        switch (v.value) {
            .string => |s| try resp.write_bulk_string(writer, s),
            .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
            .int => |i| {
                try resp.write_int_bulk_string(writer, i);
            },
            .list, .time_series, .bloom_filter, .search_index, .hash_map, .set, .zset => return error.WrongType,
        }
    } else {
        try resp.write_null(writer);
    }
}

pub fn incr(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const new_value = try incr_decr(store, key, 1);

    try resp.write_int(writer, new_value);
}

pub fn decr(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const new_value = try incr_decr(store, key, -1);

    try resp.write_int(writer, new_value);
}

fn incr_decr(store_ptr: *Store, key: []const u8, value: i64) !i64 {
    const current_value = store_ptr.get(key);
    if (current_value) |v| {
        var new_value: i64 = undefined;

        switch (v.value) {
            .string => {
                const intValue = std.fmt.parseInt(i64, v.value.string, 10) catch {
                    return error.ValueNotInteger;
                };
                new_value = std.math.add(i64, intValue, value) catch {
                    return error.Overflow;
                };
            },
            .short_string => {
                const intValue = std.fmt.parseInt(i64, v.value.short_string.as_slice(), 10) catch {
                    return error.ValueNotInteger;
                };
                new_value = std.math.add(i64, intValue, value) catch {
                    return error.Overflow;
                };
            },
            .int => {
                new_value = std.math.add(i64, v.value.int, value) catch {
                    return error.Overflow;
                };
            },
            else => return error.WrongType,
        }

        const int_object = ZedisObject{ .value = .{ .int = new_value } };
        try store_ptr.put_object(key, int_object);

        return new_value;
    } else {
        // Redis behavior: non-existent key is treated as 0, then the operation is applied
        const new_value = std.math.add(i64, 0, value) catch {
            return error.ValueNotInteger;
        };
        try store_ptr.set_int(key, new_value);
        return new_value;
    }
}

pub fn del(writer: *Writer, store: *Store, args: []const Value) !void {
    var deleted: u32 = 0;
    for (args[1..]) |key| {
        if (store.delete(key.as_slice())) {
            deleted += 1;
        }
    }

    try resp.write_int(writer, deleted);
}

/// EXPIRE key seconds [NX|XX|GT|LT]
pub fn expire(writer: *Writer, store: *Store, args: []const Value) !void {
    const seconds = args[2].as_int() catch return error.ValueNotInteger;
    const milliseconds = std.math.mul(i64, seconds, 1000) catch {
        return resp.write_error(writer, "ERR invalid expire time in 'expire' command");
    };
    return expire_with_options(writer, store, args[1].as_slice(), milliseconds, args[3..], "expire");
}

/// PEXPIRE key milliseconds [NX|XX|GT|LT]
pub fn pexpire(writer: *Writer, store: *Store, args: []const Value) !void {
    const milliseconds = args[2].as_int() catch return error.ValueNotInteger;
    return expire_with_options(writer, store, args[1].as_slice(), milliseconds, args[3..], "pexpire");
}

fn expire_with_options(
    writer: *Writer,
    store: *Store,
    key: []const u8,
    milliseconds: i64,
    option_args: []const Value,
    command_name: []const u8,
) !void {
    var nx = false;
    var xx = false;
    var gt = false;
    var lt = false;
    for (option_args) |arg| {
        const option = arg.as_slice();
        if (std.ascii.eqlIgnoreCase(option, "NX")) {
            nx = true;
        } else if (std.ascii.eqlIgnoreCase(option, "XX")) {
            xx = true;
        } else if (std.ascii.eqlIgnoreCase(option, "GT")) {
            gt = true;
        } else if (std.ascii.eqlIgnoreCase(option, "LT")) {
            lt = true;
        } else {
            var message: [128]u8 = undefined;
            const text = std.fmt.bufPrint(&message, "ERR Unsupported option {s}", .{option}) catch "ERR syntax error";
            return resp.write_error(writer, text);
        }
    }

    if ((nx and (xx or gt or lt)) or (gt and lt)) {
        return resp.write_error(writer, "ERR NX and XX, GT or LT options at the same time are not compatible");
    }

    if (!store.exists(key)) return resp.write_int(writer, 0);

    const current_expiry = store.get_ttl(key);
    if (nx and current_expiry != null) return resp.write_int(writer, 0);
    if (xx and current_expiry == null) return resp.write_int(writer, 0);

    const now = store.clock.now().toMilliseconds();

    if (milliseconds <= 0) {
        if (gt) {
            if (current_expiry == null or now <= current_expiry.?) return resp.write_int(writer, 0);
        }
        if (lt) {
            if (current_expiry) |expiry| {
                if (now >= expiry) return resp.write_int(writer, 0);
            }
        }
        return resp.write_int(writer, @intFromBool(store.delete(key)));
    }

    const new_expiry = std.math.add(i64, now, milliseconds) catch {
        var message: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&message, "ERR invalid expire time in '{s}' command", .{command_name}) catch
            "ERR invalid expire time";
        return resp.write_error(writer, text);
    };

    if (gt) {
        if (current_expiry == null or new_expiry <= current_expiry.?) {
            return resp.write_int(writer, 0);
        }
    }
    if (lt) {
        if (current_expiry) |expiry| {
            if (new_expiry >= expiry) return resp.write_int(writer, 0);
        }
    }

    const applied = try store.expire(key, new_expiry);
    try resp.write_int(writer, @intFromBool(applied));
}

pub fn expire_at(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const ts = store.clock.now();
    const current_time = ts.toMilliseconds();
    const expiration_timestamp = args[2].as_int() catch {
        return resp.write_int(writer, 0);
    };

    const result = if (expiration_timestamp <= current_time)
        store.delete(key)
    else
        store.expire(key, expiration_timestamp) catch false;

    try resp.write_int(writer, @intFromBool(result));
}

pub fn append(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const append_value = args[2].as_slice();

    const current_value = store.get(key);
    var new_value: []const u8 = undefined;
    var needs_free = false;

    if (current_value) |v| {
        const current_str = switch (v.value) {
            .string => |s| s,
            .short_string => |ss| ss.as_slice(),
            .int => |i| blk: {
                var buf: [21]u8 = undefined;
                break :blk std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            },
            else => return error.WrongType,
        };

        // Concatenate current value with append value
        const concatenated = try store.allocator.print("{s}{s}", .{ current_str, append_value });
        new_value = concatenated;
        needs_free = true;
    } else {
        new_value = append_value;
    }

    defer if (needs_free) store.allocator.free(new_value);
    try store.set(key, new_value);

    try resp.write_int(writer, new_value.len);
}

pub fn strlen(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
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
        try resp.write_int(writer, len);
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn getset(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const new_value = args[2].as_slice();

    const old_value = store.get(key);

    if (old_value) |v| {
        switch (v.value) {
            .string => |s| try resp.write_bulk_string(writer, s),
            .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
            .int => |i| try resp.write_int_bulk_string(writer, i),
            else => return error.WrongType,
        }
    } else {
        try resp.write_null(writer);
    }

    try store.set(key, new_value);
    _ = store.persist(key);
}

pub fn mget(writer: *Writer, store: *Store, args: []const Value) !void {
    try resp.write_list_len(writer, args.len - 1);

    for (args[1..]) |key_arg| {
        const key = key_arg.as_slice();
        const value = store.get(key);

        if (value) |v| {
            switch (v.value) {
                .string => |s| try resp.write_bulk_string(writer, s),
                .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
                .int => |i| try resp.write_int_bulk_string(writer, i),
                else => try resp.write_null(writer), // Lists return null
            }
        } else {
            try resp.write_null(writer);
        }
    }
}

pub fn mset(writer: *Writer, store: *Store, args: []const Value) !void {
    // Args format: MSET key1 value1 key2 value2 ...
    if (args.len % 2 != 1) {
        return error.InvalidArgument;
    }

    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const key = args[i].as_slice();
        const value = args[i + 1].as_slice();
        try store.set(key, value);
        _ = store.persist(key);
    }

    try resp.write_ok(writer);
}

pub fn setex(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const seconds = args[2].as_int() catch {
        return error.ValueNotInteger;
    };
    const value = args[3].as_slice();

    try store.set(key, value);

    if (seconds > 0) {
        const ts = store.clock.now();
        const now = ts.toMilliseconds();
        const expiration_time = now + (seconds * 1000);
        _ = try store.expire(key, expiration_time);
    }

    try resp.write_ok(writer);
}

pub fn setnx(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = args[2].as_slice();

    const exists = store.get(key) != null;

    if (!exists) {
        try store.set(key, value);
        try resp.write_int(writer, 1);
    } else {
        try resp.write_int(writer, 0);
    }
}

pub fn incrby(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const increment = args[2].as_int() catch {
        return error.ValueNotInteger;
    };

    const new_value = try incr_decr(store, key, increment);
    try resp.write_int(writer, new_value);
}

pub fn decrby(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const decrement = args[2].as_int() catch {
        return error.ValueNotInteger;
    };

    const negated = std.math.negate(decrement) catch return error.Overflow;
    const new_value = try incr_decr(store, key, negated);
    try resp.write_int(writer, new_value);
}

pub fn incrbyfloat(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const increment_str = args[2].as_slice();

    const increment = std.fmt.parseFloat(f64, increment_str) catch {
        return error.InvalidFloat;
    };

    const current_value = store.get(key);
    var current_float: f64 = 0.0;

    if (current_value) |v| {
        switch (v.value) {
            .string => |s| {
                current_float = std.fmt.parseFloat(f64, s) catch {
                    return error.InvalidFloat;
                };
            },
            .short_string => |ss| {
                current_float = std.fmt.parseFloat(f64, ss.as_slice()) catch {
                    return error.InvalidFloat;
                };
            },
            .int => |i| {
                current_float = @floatFromInt(i);
            },
            else => return error.WrongType,
        }
    }

    const new_float = current_float + increment;

    // Format to string with up to 17 decimal places, removing trailing zeros
    var buf: [64]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d:.17}", .{new_float}) catch {
        return error.Overflow;
    };

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

    try store.set(key, result);

    try resp.write_bulk_string(writer, result);
}

fn write_string_value(writer: *Writer, obj: *const ZedisObject) !void {
    switch (obj.value) {
        .string => |s| try resp.write_bulk_string(writer, s),
        .short_string => |ss| try resp.write_bulk_string(writer, ss.as_slice()),
        .int => |i| try resp.write_int_bulk_string(writer, i),
        .list, .time_series, .bloom_filter, .search_index, .hash_map, .set, .zset => return error.WrongType,
    }
}

/// GET key [EX seconds | PX milliseconds | EXAT unix-time-seconds | PXAT unix-time-milliseconds | PERSIST]
pub fn getex(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const obj = store.get(key) orelse {
        try resp.write_null(writer);
        return;
    };

    try write_string_value(writer, obj);

    if (args.len == 2) return;

    const opt = args[2].as_slice();
    const upper_buf_len = 8;
    var upper_buf: [upper_buf_len]u8 = undefined;
    const opt_up = std.ascii.upperString(upper_buf[0..@min(opt.len, upper_buf_len)], opt);

    if (std.mem.eql(u8, opt_up, "PERSIST")) {
        _ = store.persist(key);
    } else if (args.len >= 4) {
        const amount = args[3].as_int() catch return error.ValueNotInteger;
        const now = store.clock.now().toMilliseconds();
        if (std.mem.eql(u8, opt_up, "EX")) {
            _ = try store.expire(key, now + amount * 1000);
        } else if (std.mem.eql(u8, opt_up, "PX")) {
            _ = try store.expire(key, now + amount);
        } else if (std.mem.eql(u8, opt_up, "EXAT")) {
            _ = try store.expire(key, amount * 1000);
        } else if (std.mem.eql(u8, opt_up, "PXAT")) {
            _ = try store.expire(key, amount);
        } else {
            return error.InvalidArgument;
        }
    } else {
        return error.InvalidArgument;
    }
}

pub fn getdel(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const obj = store.get(key) orelse {
        try resp.write_null(writer);
        return;
    };

    try write_string_value(writer, obj);
    _ = store.delete(key);
}

pub fn getrange(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const start_raw = args[2].as_int() catch return error.ValueNotInteger;
    const end_raw = args[3].as_int() catch return error.ValueNotInteger;

    var value_buf: [64]u8 = undefined;
    const str: []const u8 = blk: {
        const obj = store.get(key) orelse {
            try resp.write_bulk_string(writer, "");
            return;
        };
        break :blk switch (obj.value) {
            .string => |s| s,
            .short_string => |ss| ss.as_slice(),
            .int => |i| std.fmt.bufPrint(&value_buf, "{d}", .{i}) catch {
                try resp.write_bulk_string(writer, "");
                return;
            },
            else => return error.WrongType,
        };
    };

    const len = str.len;
    if (len == 0) {
        try resp.write_bulk_string(writer, "");
        return;
    }

    const start: usize = if (start_raw < 0) blk: {
        const off = @as(usize, @intCast(-start_raw));
        break :blk if (off > len) 0 else len - off;
    } else @intCast(start_raw);

    const end: usize = if (end_raw < 0) blk: {
        const off = @as(usize, @intCast(-end_raw));
        break :blk if (off > len) 0 else len - off;
    } else @min(@as(usize, @intCast(end_raw)), len - 1);

    if (start > end or start >= len) {
        try resp.write_bulk_string(writer, "");
        return;
    }

    try resp.write_bulk_string(writer, str[start .. end + 1]);
}

pub fn setrange(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const offset = args[2].as_int() catch return error.ValueNotInteger;
    if (offset < 0) return error.InvalidArgument;
    const replacement = args[3].as_slice();

    const off: usize = @intCast(offset);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(store.allocator);

    if (store.get(key)) |obj| {
        switch (obj.value) {
            .string => |s| try buf.appendSlice(store.allocator, s),
            .short_string => |ss| try buf.appendSlice(store.allocator, ss.as_slice()),
            .int => |i| {
                var tmp: [32]u8 = undefined;
                const formatted = std.fmt.bufPrint(&tmp, "{d}", .{i}) catch return error.Overflow;
                try buf.appendSlice(store.allocator, formatted);
            },
            else => return error.WrongType,
        }
    }

    const required_len = off + replacement.len;
    if (buf.items.len < required_len) {
        const old_len = buf.items.len;
        try buf.resize(store.allocator, required_len);
        @memset(buf.items[old_len..], 0);
    }

    @memcpy(buf.items[off .. off + replacement.len], replacement);

    try store.set(key, buf.items);
    try resp.write_int(writer, buf.items.len);
}

pub fn psetex(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const ms = args[2].as_int() catch return error.ValueNotInteger;
    const value = args[3].as_slice();

    if (ms <= 0) return error.InvalidArgument;

    try store.set(key, value);
    const now = store.clock.now().toMilliseconds();
    _ = try store.expire(key, now + ms);

    try resp.write_ok(writer);
}

pub fn msetnx(writer: *Writer, store: *Store, args: []const Value) !void {
    if ((args.len - 1) % 2 != 0) return error.WrongNumberOfArguments;

    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (store.get(args[i].as_slice()) != null) {
            try resp.write_int(writer, 0);
            return;
        }
    }

    i = 1;
    while (i < args.len) : (i += 2) {
        try store.set(args[i].as_slice(), args[i + 1].as_slice());
    }
    try resp.write_int(writer, 1);
}

/// Full SET with options: SET key value [NX|XX] [GET] [EX n | PX n | EXAT n | PXAT n | KEEPTTL]
pub fn set_full(writer: *Writer, store: *Store, args: []const Value) !void {
    const key = args[1].as_slice();
    const value = args[2].as_slice();

    var nx = false;
    var xx = false;
    var get_flag = false;
    var keepttl = false;
    var expiry_ms: ?i64 = null;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        var buf: [8]u8 = undefined;
        const opt = args[i].as_slice();
        const opt_up = std.ascii.upperString(buf[0..@min(opt.len, buf.len)], opt);

        if (std.mem.eql(u8, opt_up, "NX")) {
            nx = true;
        } else if (std.mem.eql(u8, opt_up, "XX")) {
            xx = true;
        } else if (std.mem.eql(u8, opt_up, "GET")) {
            get_flag = true;
        } else if (std.mem.eql(u8, opt_up, "KEEPTTL")) {
            keepttl = true;
        } else if (std.mem.eql(u8, opt_up, "EX") or std.mem.eql(u8, opt_up, "PX") or
            std.mem.eql(u8, opt_up, "EXAT") or std.mem.eql(u8, opt_up, "PXAT"))
        {
            i += 1;
            if (i >= args.len) return error.WrongNumberOfArguments;
            const amount = args[i].as_int() catch return error.ValueNotInteger;
            if (amount <= 0) return error.InvalidArgument;
            const now = store.clock.now().toMilliseconds();
            if (std.mem.eql(u8, opt_up, "EX")) {
                expiry_ms = now + amount * 1000;
            } else if (std.mem.eql(u8, opt_up, "PX")) {
                expiry_ms = now + amount;
            } else if (std.mem.eql(u8, opt_up, "EXAT")) {
                expiry_ms = amount * 1000;
            } else {
                expiry_ms = amount;
            }
        } else {
            return error.InvalidArgument;
        }
    }

    const existing = store.get(key);

    if (get_flag) {
        if (existing) |obj| {
            try write_string_value(writer, obj);
        } else {
            try resp.write_null(writer);
        }
    }

    if (nx and existing != null) {
        if (!get_flag) try resp.write_null(writer);
        return;
    }
    if (xx and existing == null) {
        if (!get_flag) try resp.write_null(writer);
        return;
    }

    const old_ttl: ?i64 = if (keepttl) store.get_ttl(key) else null;

    try store.set(key, value);

    if (expiry_ms) |exp| {
        _ = try store.expire(key, exp);
    } else if (old_ttl) |ttl| {
        _ = try store.expire(key, ttl);
    } else {
        // Redis discards the TTL on a plain SET; KEEPTTL is the opt-in.
        _ = store.persist(key);
    }

    if (!get_flag) try resp.write_ok(writer);
}

test "SET command with string value" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "hello" },
    };

    try set(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("hello", stored_value.?.value.short_string.as_slice());
}

test "SET command with integer value" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SET" },
        .{ .data = "key1" },
        .{ .data = "42" },
    };

    try set(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("42", stored_value.?.value.short_string.as_slice());
}

test "GET command with existing string value" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$5\r\nhello\r\n", writer.buffered());
}

test "GET command with existing integer value" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("key1", 42);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "key1" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$2\r\n42\r\n", writer.buffered());
}

test "GET command with non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "nonexistent" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());
}

test "INCR command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try incr(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 1), stored_value.?.value.int);
}

test "INCR command on existing integer" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("counter", 5);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try incr(&writer, &store, &args);

    try testing.expectEqualStrings(":6\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 6), stored_value.?.value.int);
}

test "INCR command on string that represents integer" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("counter", "10");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try incr(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 11), stored_value.?.value.int);
}

test "INCR command on non-integer string" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "hello");

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "key1" },
    };

    const result = incr(&writer, &store, &args);
    try testing.expectError(error.ValueNotInteger, result);
}

test "DECR command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try decr(&writer, &store, &args);

    try testing.expectEqualStrings(":-1\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -1), stored_value.?.value.int);
}

test "DECR command on existing integer" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("counter", 10);

    const args = [_]Value{
        .{ .data = "DECR" },
        .{ .data = "counter" },
    };

    try decr(&writer, &store, &args);

    try testing.expectEqualStrings(":9\r\n", writer.buffered());

    const stored_value = store.get("counter");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 9), stored_value.?.value.int);
}

test "DEL command with single existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "value1");

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
    };

    try del(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("key1");
    try testing.expect(stored_value == null);
}

test "DEL command with multiple keys" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set_int("key3", 42);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
        .{ .data = "nonexistent" },
    };

    try del(&writer, &store, &args);

    try testing.expectEqualStrings(":3\r\n", writer.buffered());

    try testing.expect(store.get("key1") == null);
    try testing.expect(store.get("key2") == null);
    try testing.expect(store.get("key3") == null);
}

test "DEL command with non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = "nonexistent" },
    };

    try del(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "APPEND command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "APPEND" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try append(&writer, &store, &args);

    try testing.expectEqualStrings(":5\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.as_slice());
}

test "APPEND command on existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "Hello");

    const args = [_]Value{
        .{ .data = "APPEND" },
        .{ .data = "mykey" },
        .{ .data = " World" },
    };

    try append(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello World", stored_value.?.value.short_string.as_slice());
}

test "STRLEN command on existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "Hello World");

    const args = [_]Value{
        .{ .data = "STRLEN" },
        .{ .data = "mykey" },
    };

    try strlen(&writer, &store, &args);

    try testing.expectEqualStrings(":11\r\n", writer.buffered());
}

test "STRLEN command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "STRLEN" },
        .{ .data = "nonexistent" },
    };

    try strlen(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
}

test "GETSET command on existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "Hello");

    const args = [_]Value{
        .{ .data = "GETSET" },
        .{ .data = "mykey" },
        .{ .data = "World" },
    };

    try getset(&writer, &store, &args);

    try testing.expectEqualStrings("$5\r\nHello\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.as_slice());
}

test "GETSET command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GETSET" },
        .{ .data = "mykey" },
        .{ .data = "World" },
    };

    try getset(&writer, &store, &args);

    try testing.expectEqualStrings("$-1\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.as_slice());
}

test "MGET command with multiple keys" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("key1", "value1");
    try store.set_int("key2", 42);

    const args = [_]Value{
        .{ .data = "MGET" },
        .{ .data = "key1" },
        .{ .data = "key2" },
        .{ .data = "key3" },
    };

    try mget(&writer, &store, &args);

    try testing.expectEqualStrings("*3\r\n$6\r\nvalue1\r\n$2\r\n42\r\n$-1\r\n", writer.buffered());
}

test "MSET command with multiple key-value pairs" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "MSET" },
        .{ .data = "key1" },
        .{ .data = "value1" },
        .{ .data = "key2" },
        .{ .data = "value2" },
    };

    try mset(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const v1 = store.get("key1");
    try testing.expect(v1 != null);
    try testing.expectEqualStrings("value1", v1.?.value.short_string.as_slice());

    const v2 = store.get("key2");
    try testing.expect(v2 != null);
    try testing.expectEqualStrings("value2", v2.?.value.short_string.as_slice());
}

test "SETEX command sets key with expiration" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SETEX" },
        .{ .data = "mykey" },
        .{ .data = "10" },
        .{ .data = "Hello" },
    };

    try setex(&writer, &store, &args);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.as_slice());
}

test "SETNX command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try setnx(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("Hello", stored_value.?.value.short_string.as_slice());
}

test "SETNX command on existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "World");

    const args = [_]Value{
        .{ .data = "SETNX" },
        .{ .data = "mykey" },
        .{ .data = "Hello" },
    };

    try setnx(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqualStrings("World", stored_value.?.value.short_string.as_slice());
}

test "INCRBY command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "mykey" },
        .{ .data = "5" },
    };

    try incrby(&writer, &store, &args);

    try testing.expectEqualStrings(":5\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 5), stored_value.?.value.int);
}

test "INCRBY command on existing integer" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("mykey", 10);

    const args = [_]Value{
        .{ .data = "INCRBY" },
        .{ .data = "mykey" },
        .{ .data = "5" },
    };

    try incrby(&writer, &store, &args);

    try testing.expectEqualStrings(":15\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 15), stored_value.?.value.int);
}

test "DECRBY command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "mykey" },
        .{ .data = "3" },
    };

    try decrby(&writer, &store, &args);

    try testing.expectEqualStrings(":-3\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, -3), stored_value.?.value.int);
}

test "DECRBY command on existing integer" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set_int("mykey", 10);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "mykey" },
        .{ .data = "3" },
    };

    try decrby(&writer, &store, &args);

    try testing.expectEqualStrings(":7\r\n", writer.buffered());

    const stored_value = store.get("mykey");
    try testing.expect(stored_value != null);
    try testing.expectEqual(@as(i64, 7), stored_value.?.value.int);
}

test "INCRBYFLOAT command on non-existing key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "2.5" },
    };

    try incrbyfloat(&writer, &store, &args);

    try testing.expectEqualStrings("$3\r\n2.5\r\n", writer.buffered());
}

test "INCRBYFLOAT command on existing float" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "10.5");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "0.1" },
    };

    try incrbyfloat(&writer, &store, &args);

    // Result should be "10.6" (trailing zeros removed)
    try testing.expectEqualStrings("$4\r\n10.6\r\n", writer.buffered());
}

test "INCRBYFLOAT command with negative increment" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try store.set("mykey", "5.0");

    const args = [_]Value{
        .{ .data = "INCRBYFLOAT" },
        .{ .data = "mykey" },
        .{ .data = "-2.0" },
    };

    try incrbyfloat(&writer, &store, &args);

    // Result should be "3" (trailing zeros and decimal point removed)
    try testing.expectEqualStrings("$1\r\n3\r\n", writer.buffered());
}

test "INCR command overflow returns Overflow" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set_int("counter", std.math.maxInt(i64));

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = "counter" },
    };

    try testing.expectError(error.Overflow, incr(&writer, &store, &args));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), store.get("counter").?.value.int);
}

test "DECRBY command with minimum i64 decrement returns Overflow" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "DECRBY" },
        .{ .data = "counter" },
        .{ .data = "-9223372036854775808" },
    };

    try testing.expectError(error.Overflow, decrby(&writer, &store, &args));
}

test "GET command on minimum i64 value" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set_int("counter", std.math.minInt(i64));

    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "GET" },
        .{ .data = "counter" },
    };

    try get(&writer, &store, &args);

    try testing.expectEqualStrings("$20\r\n-9223372036854775808\r\n", writer.buffered());
}

test "PEXPIRE sets a millisecond expiry" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "value");

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "PEXPIRE" },
        .{ .data = "mykey" },
        .{ .data = "5000" },
    };

    try pexpire(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());
    const expires_at = store.get_ttl("mykey").?;
    const now = Io.Clock.real.now(testing.io).toMilliseconds();
    try testing.expect(expires_at > now);
    try testing.expect(expires_at <= now + 5000);
}

test "PEXPIRE with a non-positive TTL deletes the key" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "value");

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "PEXPIRE" },
        .{ .data = "mykey" },
        .{ .data = "0" },
    };

    try pexpire(&writer, &store, &args);

    try testing.expectEqualStrings(":1\r\n", writer.buffered());
    try testing.expect(!store.exists("mykey"));
}

test "PEXPIRE NX leaves an existing expiry unchanged" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "value");
    const now = Io.Clock.real.now(testing.io).toMilliseconds();
    _ = try store.expire("mykey", now + 10000);

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "PEXPIRE" },
        .{ .data = "mykey" },
        .{ .data = "5000" },
        .{ .data = "NX" },
    };

    try pexpire(&writer, &store, &args);

    try testing.expectEqualStrings(":0\r\n", writer.buffered());
    try testing.expectEqual(now + 10000, store.get_ttl("mykey").?);
}

test "SET discards the previous expiry unless KEEPTTL is given" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "v1");
    _ = try store.expire("mykey", clock.now().toMilliseconds() + 60_000);

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    const plain = [_]Value{ .{ .data = "SET" }, .{ .data = "mykey" }, .{ .data = "v2" } };
    try set_full(&writer, &store, &plain);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    try testing.expect(store.get_ttl("mykey") == null);

    writer = Writer.fixed(&buffer);
    const keep = [_]Value{
        .{ .data = "SET" }, .{ .data = "mykey" }, .{ .data = "v3" }, .{ .data = "KEEPTTL" },
    };
    _ = try store.expire("mykey", clock.now().toMilliseconds() + 60_000);
    try set_full(&writer, &store, &keep);
    try testing.expect(store.get_ttl("mykey") != null);
}

test "MSET and GETSET discard the previous expiry" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    const expiry = clock.now().toMilliseconds() + 60_000;

    try store.set("mset-key", "v1");
    _ = try store.expire("mset-key", expiry);
    try mset(&writer, &store, &[_]Value{
        .{ .data = "MSET" }, .{ .data = "mset-key" }, .{ .data = "v2" },
    });
    try testing.expect(store.get_ttl("mset-key") == null);

    try store.set("getset-key", "v1");
    _ = try store.expire("getset-key", expiry);
    writer = Writer.fixed(&buffer);
    try getset(&writer, &store, &[_]Value{
        .{ .data = "GETSET" }, .{ .data = "getset-key" }, .{ .data = "v2" },
    });
    try testing.expect(store.get_ttl("getset-key") == null);
}

test "EXPIRE honours NX, GT and LT instead of resetting the expiry" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "value");

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    try expire(&writer, &store, &[_]Value{
        .{ .data = "EXPIRE" }, .{ .data = "mykey" }, .{ .data = "100" },
    });
    try testing.expectEqualStrings(":1\r\n", writer.buffered());
    const original = store.get_ttl("mykey").?;

    writer = Writer.fixed(&buffer);
    try expire(&writer, &store, &[_]Value{
        .{ .data = "EXPIRE" }, .{ .data = "mykey" }, .{ .data = "30" }, .{ .data = "NX" },
    });
    try testing.expectEqualStrings(":0\r\n", writer.buffered());
    try testing.expectEqual(original, store.get_ttl("mykey").?);

    writer = Writer.fixed(&buffer);
    try expire(&writer, &store, &[_]Value{
        .{ .data = "EXPIRE" }, .{ .data = "mykey" }, .{ .data = "20" }, .{ .data = "GT" },
    });
    try testing.expectEqualStrings(":0\r\n", writer.buffered());
    try testing.expectEqual(original, store.get_ttl("mykey").?);

    writer = Writer.fixed(&buffer);
    try expire(&writer, &store, &[_]Value{
        .{ .data = "EXPIRE" }, .{ .data = "mykey" }, .{ .data = "200" }, .{ .data = "GT" },
    });
    try testing.expectEqualStrings(":1\r\n", writer.buffered());
    try testing.expect(store.get_ttl("mykey").? > original);
}

test "EXPIRE rejects a non-integer TTL" {
    const allocator = testing.allocator;

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("mykey", "value");

    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try testing.expectError(error.ValueNotInteger, expire(&writer, &store, &[_]Value{
        .{ .data = "EXPIRE" }, .{ .data = "mykey" }, .{ .data = "soon" },
    }));
    try testing.expect(store.get_ttl("mykey") == null);
}
