const std = @import("std");
const testing = std.testing;
const Writer = std.Io.Writer;

const Clock = @import("../clock.zig");
const Store = @import("../store.zig").Store;
const KeyValueAllocator = @import("../kv_allocator.zig");
const Server = @import("../server.zig");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const connection_commands = @import("../commands/connection.zig");

const TestContext = struct {
    allocator: std.mem.Allocator,
    clock: Clock,
    server: Server,
    client: Client,

    fn init(self: *TestContext, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.clock = Clock.init(testing.io, 0);

        self.server = undefined;
        self.server.config = .{
            .appendonly = false,
            .kv_memory_budget = 4096,
            .maxmemory_samples = 5,
            .eviction_policy = .allkeys_lru,
        };
        self.server.store = try Store.init(allocator, testing.io, &self.clock, .{
            .initial_capacity = 16,
            .eviction_policy = .allkeys_lru,
            .maxmemory_samples = 5,
        });
        self.server.kv_allocator = try KeyValueAllocator.init(allocator, 4096, .allkeys_lru);

        self.client = undefined;
        self.client.allocator = allocator;
        self.client.server = &self.server;
    }

    fn deinit(self: *TestContext) void {
        self.server.store.deinit();
        if (self.server.config.requirepass) |password| {
            self.allocator.free(password);
        }
    }
};

test "CONFIG GET returns exact parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "GET" },
        .{ .data = "appendonly" },
    };

    try connection_commands.config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("*2\r\n$10\r\nappendonly\r\n$2\r\nno\r\n", writer.buffered());
}

test "CONFIG GET resolves exact alias to canonical name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "GET" },
        .{ .data = "kv-memory-budget" },
    };

    try connection_commands.config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("*2\r\n$9\r\nmaxmemory\r\n$4\r\n4096\r\n", writer.buffered());
}

test "CONFIG GET supports wildcard patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    ctx.server.config.maxmemory_samples = 9;
    ctx.server.store.maxmemory_samples = 9;
    ctx.server.config.eviction_policy = .volatile_lru;
    ctx.server.store.eviction_policy = .volatile_lru;

    var buffer: [512]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "GET" },
        .{ .data = "maxmemory*" },
    };

    try connection_commands.config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings(
        "*6\r\n" ++
            "$9\r\nmaxmemory\r\n$4\r\n4096\r\n" ++
            "$16\r\nmaxmemory-policy\r\n$12\r\nvolatile-lru\r\n" ++
            "$17\r\nmaxmemory-samples\r\n$1\r\n9\r\n",
        writer.buffered(),
    );
}

test "CONFIG SET updates supported runtime parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "SET" },
        .{ .data = "maxmemory-samples" },
        .{ .data = "11" },
        .{ .data = "eviction-policy" },
        .{ .data = "noeviction" },
        .{ .data = "requirepass" },
        .{ .data = "secret" },
    };

    try connection_commands.config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    try testing.expectEqual(@as(u32, 11), ctx.server.config.maxmemory_samples);
    try testing.expectEqual(@as(usize, 11), ctx.server.store.maxmemory_samples);
    try testing.expectEqual(.noeviction, ctx.server.config.eviction_policy);
    try testing.expectEqual(.noeviction, ctx.server.store.eviction_policy);
    try testing.expectEqual(.noeviction, ctx.server.kv_allocator.eviction_policy);
    try testing.expectEqualStrings("secret", ctx.server.config.requirepass.?);
}

test "CONFIG SET rejects immutable parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "SET" },
        .{ .data = "appendonly" },
        .{ .data = "yes" },
    };

    try connection_commands.config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("-ERR CONFIG SET does not support runtime updates for 'appendonly'\r\n", writer.buffered());
    try testing.expect(!ctx.server.config.appendonly);
}
