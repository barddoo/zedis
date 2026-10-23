const std = @import("std");
const storeModule = @import("../storage/store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");

pub fn flush_all(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    client.get_current_store().flush_db();
    try resp.write_ok(writer);
}

pub fn flush_db(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    client.get_current_store().flush_db();
    try resp.write_ok(writer);
}

pub fn db_size(writer: *std.Io.Writer, store: *Store, _: []const Value) !void {
    try resp.write_int(writer, store.size());
}
