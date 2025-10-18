const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");

pub fn keys(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const pattern = args[1].asSlice();

    const all_keys = try store.keys(store.allocator, pattern);
    defer store.allocator.free(all_keys);
    try resp.writeListLen(writer, all_keys.len);
    for (all_keys) |key| {
        try resp.writeBulkString(writer, key);
    }
}

pub fn exists(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    if (store.exists(key)) {
        try resp.writeInt(writer, 1);
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn ttl(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const exists_key = store.exists(key);

    if (!exists_key) {
        try resp.writeInt(writer, -2);
        return;
    }
    const ttl_int = store.getTtl(key) orelse -1;
    try resp.writeInt(writer, ttl_int);
}

pub fn persist(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const result = store.persist(key);
    if (result) {
        try resp.writeInt(writer, 1);
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn typeCmd(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const obj = store.get(key);

    const type_str = if (obj) |o| switch (o.value) {
        .string, .short_string, .int => "string",
        .list => "list",
        .time_series => "tseries-type",
    } else "none";

    try resp.writeBulkString(writer, type_str);
}

pub fn rename(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const old_key = args[1].asSlice();
    const new_key = args[2].asSlice();

    const obj = store.get(old_key) orelse {
        return error.KeyNotFound;
    };

    try store.putObject(new_key, obj.*);
    _ = store.delete(old_key);

    try resp.writeSimpleString(writer, "OK");
}

pub fn randomkey(writer: *std.Io.Writer, store: *Store, _: []const Value) !void {
    var random = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    const key = store.randomKey(random.random());

    if (key) |k| {
        try resp.writeBulkString(writer, k);
    } else {
        try resp.writeNull(writer);
    }
}
