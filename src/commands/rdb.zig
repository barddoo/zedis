const std = @import("std");
const store = @import("../store.zig");
const Store = store.Store;
const ZedisObject = store.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const ZDB = @import("../rdb/zdb.zig");
const resp = @import("./resp.zig");

pub fn save(client: *Client, args: []const Value) !void {
    _ = args;
    var sw = client.connection.stream.writer(&.{});
    const writer = &sw.interface;

    var zdb = try ZDB.Writer.init(client.allocator, client.store, "test.rdb");
    defer zdb.deinit();
    try zdb.writeFile();

    try resp.writeOK(writer);
}
