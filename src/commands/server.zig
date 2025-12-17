const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("./resp.zig");

pub fn flush_all(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    // Flush all databases across all shards
    for (client.server.shards) |*shard| {
        for (&shard.databases) |*db| {
            db.flush_db();
        }
    }
    try resp.writeOK(writer);
}

pub fn flush_db(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    // Flush current database across all shards
    for (client.server.shards) |*shard| {
        shard.databases[client.current_db].flush_db();
    }
    try resp.writeOK(writer);
}

pub fn db_size(writer: *std.Io.Writer, store: *Store, _: []const Value) !void {
    try resp.writeInt(writer, store.size());
}
