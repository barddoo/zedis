const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const ValueType = storeModule.ValueType;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const pattern_matcher = @import("../pattern_matcher.zig");

pub fn exists(client: *Client, args: []const Value) !void {
    var count: usize = 0;
    for (args[1..]) |key_arg| {
        const key = key_arg.asSlice();
        if (client.store.exists(key)) {
            count += 1;
        }
    }
    try client.writeInt(count);
}

pub fn typeCmd(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();

    if (client.store.getType(key)) |value_type| {
        const type_str = switch (value_type) {
            .string, .int => "string",
            .list => "list",
        };
        try client.writeBulkString(type_str);
    } else {
        try client.writeBulkString("none");
    }
}

pub fn ttl(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();
    const ttl_value = client.store.ttl(key);
    try client.writeInt(ttl_value);
}

pub fn persist(client: *Client, args: []const Value) !void {
    const key = args[1].asSlice();

    if (client.store.map.getPtr(key)) |entry| {
        if (entry.expiration != null) {
            entry.expiration = null;
            try client.writeInt(1);
        } else {
            try client.writeInt(0);
        }
    } else {
        try client.writeInt(0);
    }
}

pub fn rename(client: *Client, args: []const Value) !void {
    const old_key = args[1].asSlice();
    const new_key = args[2].asSlice();

    // Can't rename to itself
    if (std.mem.eql(u8, old_key, new_key)) {
        return client.writeBulkString("OK");
    }

    try client.store.rename(old_key, new_key);

    try client.writeBulkString("OK");
}

pub fn keys(client: *Client, args: []const Value) !void {
    const pattern = args[1].asSlice();

    var matching_keys = std.ArrayList([]const u8){};
    defer matching_keys.deinit(client.allocator);

    var it = client.store.map.iterator();
    while (it.next()) |entry| {
        if (pattern_matcher.matchPattern(pattern, entry.key_ptr.*)) {
            try matching_keys.append(client.allocator, entry.key_ptr.*);
        }
    }

    try client.writeListLen(matching_keys.items.len);
    for (matching_keys.items) |key| {
        try client.writeBulkString(key);
    }
}

pub fn randomkey(client: *Client, _: []const Value) !void {
    const count = client.store.map.count();
    if (count == 0) {
        return client.writeNull();
    }

    // Get a random index
    var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
    const random = prng.random();
    const random_index = random.intRangeAtMost(usize, 0, count - 1);

    // Iterate to the random index
    var it = client.store.map.iterator();
    var i: usize = 0;
    while (it.next()) |entry| {
        if (i == random_index) {
            return client.writeBulkString(entry.key_ptr.*);
        }
        i += 1;
    }

    // Fallback (should never reach here)
    return client.writeNull();
}
