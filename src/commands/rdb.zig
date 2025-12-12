const std = @import("std");
const store = @import("../store.zig");
const Store = store.Store;
const ZedisObject = store.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const ZDB = @import("../rdb/zdb.zig");
const resp = @import("./resp.zig");

pub fn save(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    _ = args;

    // SAVE command saves the currently selected database
    var zdb = try ZDB.Writer.init(client.allocator, client.getCurrentStore(), "test.rdb", client.server.config, client.server.io);
    defer zdb.deinit();
    try zdb.writeFile();

    try resp.writeOK(writer);
}
