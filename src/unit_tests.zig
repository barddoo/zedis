comptime {
    // String commands tests
    _ = @import("commands/string.zig");

    // Core functionality tests
    _ = @import("store.zig");
    _ = @import("parser.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
    _ = @import("testing/store.zig");
    _ = @import("testing/string.zig");
    _ = @import("testing/list.zig");
    _ = @import("testing/time_series.zig");
    _ = @import("testing/keys.zig");
    _ = @import("util/string_match.zig");

    // Pub/Sub tests
    _ = @import("commands/pubsub.zig");

    _ = @import("rdb/zdb.zig");

    // AOF tests
    _ = @import("aof/aof.zig");

    // Test utilities
    _ = @import("test_utils.zig");

    // Test runner framework
    _ = @import("test_runner.zig");
}
