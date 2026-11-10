const std = @import("std");
const store = @import("../storage/store.zig");
const Store = store.Store;
const ZedisObject = store.ZedisObject;
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const ZDB = @import("../persistence/zdb.zig");
const resp = @import("../protocol/resp.zig");

pub fn save(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    _ = args;

    // SAVE must not suspend the coroutine: command execution has no store lock,
    // so a suspension here would let another client run while the snapshot
    // walks the store. Blocking I/O stalls the single executor for the
    // duration, which is what Redis' SAVE does to the server too.
    //
    // A local `init_single_threaded` instance is the intended way to get a
    // blocking Io; std documents `global_single_threaded` as a debugging
    // escape hatch. The instance stays on this stack frame and `io` is not
    // retained past `write_file`.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // SAVE command persists the single store
    var zdb = try ZDB.Writer.init(client.allocator, client.get_current_store(), client.server.config.dbfilename, client.server.config, io);
    defer zdb.deinit();
    try zdb.write_file();

    client.server.stats.rdb_changes_since_last_save = 0;
    client.server.stats.rdb_last_save_time = @divTrunc(client.server.clock.now().toMilliseconds(), 1000);

    try resp.write_ok(writer);
}
