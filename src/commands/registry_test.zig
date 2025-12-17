const std = @import("std");
const testing = std.testing;
const CommandRegistry = @import("registry.zig").CommandRegistry;
const CommandInfo = @import("registry.zig").CommandInfo;
const Value = @import("../parser.zig").Value;
const connection = @import("connection.zig");

test "registry get exact uppercase match - fast path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    const cmd = registry.get("PING");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("PING", cmd.?.name);
}

test "registry get lowercase - slow path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    const cmd = registry.get("ping");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("PING", cmd.?.name);
}

test "registry get mixed case - slow path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    const cmd = registry.get("PiNg");
    try testing.expect(cmd != null);
    try testing.expectEqualStrings("PING", cmd.?.name);
}

test "registry get all case variations return same CommandInfo" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    // Test all case variations
    const variations = [_][]const u8{
        "PING", "ping", "Ping", "PiNg", "pInG", "PINg", "piNG",
    };

    for (variations) |variant| {
        const cmd = registry.get(variant);
        try testing.expect(cmd != null);
        try testing.expectEqualStrings("PING", cmd.?.name);
        try testing.expectEqual(@as(usize, 1), cmd.?.min_args);
        try testing.expectEqual(@as(?usize, 2), cmd.?.max_args);
    }
}

test "registry get command too long returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    // Buffer size is 32 bytes in registry.get()
    const long_command = "VERYLONGCOMMANDNAMETHATEXCEEDS32BYTES";
    const cmd = registry.get(long_command);

    try testing.expect(cmd == null);
}

test "registry get unknown command returns null" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    const cmd = registry.get("UNKNOWN");
    try testing.expect(cmd == null);
}

test "registry case insensitive for multiple standard commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = CommandRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    try registry.register(.{
        .name = "ECHO",
        .handler = .{ .default = connection.echo },
        .min_args = 2,
        .max_args = 2,
        .description = "Echo the given string",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    try registry.register(.{
        .name = "CONFIG",
        .handler = .{ .default = connection.config },
        .min_args = 1,
        .max_args = null,
        .description = "Get or set configuration parameters",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    // Test each command with different case variations
    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "ping", .expected = "PING" },
        .{ .input = "Ping", .expected = "PING" },
        .{ .input = "PING", .expected = "PING" },
        .{ .input = "echo", .expected = "ECHO" },
        .{ .input = "Echo", .expected = "ECHO" },
        .{ .input = "ECHO", .expected = "ECHO" },
        .{ .input = "config", .expected = "CONFIG" },
        .{ .input = "Config", .expected = "CONFIG" },
        .{ .input = "CONFIG", .expected = "CONFIG" },
    };

    for (test_cases) |test_case| {
        const cmd = registry.get(test_case.input);
        try testing.expect(cmd != null);
        try testing.expectEqualStrings(test_case.expected, cmd.?.name);
    }
}

test "registry clone creates independent copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var original = CommandRegistry.init(allocator);
    defer original.deinit();

    try original.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    // Clone the registry
    var cloned = try original.clone(allocator);
    defer cloned.deinit();

    // Verify clone has the command
    const cmd_original = original.get("PING");
    const cmd_cloned = cloned.get("PING");

    try testing.expect(cmd_original != null);
    try testing.expect(cmd_cloned != null);
    try testing.expectEqualStrings(cmd_original.?.name, cmd_cloned.?.name);

    // Verify they are independent (different HashMap instances)
    try testing.expect(@intFromPtr(&original.commands) != @intFromPtr(&cloned.commands));
}

test "registry clone preserves all commands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var original = CommandRegistry.init(allocator);
    defer original.deinit();

    try original.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    try original.register(.{
        .name = "ECHO",
        .handler = .{ .default = connection.echo },
        .min_args = 2,
        .max_args = 2,
        .description = "Echo",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    var cloned = try original.clone(allocator);
    defer cloned.deinit();

    // Both should have both commands
    try testing.expect(cloned.get("PING") != null);
    try testing.expect(cloned.get("ECHO") != null);

    // Verify case-insensitive access works in cloned registry
    try testing.expect(cloned.get("ping") != null);
    try testing.expect(cloned.get("echo") != null);
}

test "registry clone is independent - modifications don't affect original" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var original = CommandRegistry.init(allocator);
    defer original.deinit();

    try original.register(.{
        .name = "PING",
        .handler = .{ .default = connection.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    var cloned = try original.clone(allocator);
    defer cloned.deinit();

    // Add a command to cloned registry
    try cloned.register(.{
        .name = "ECHO",
        .handler = .{ .default = connection.echo },
        .min_args = 2,
        .max_args = 2,
        .description = "Echo",
        .write_to_aof = false,
        .routing_type = .client_only,
        .key_arg_index = null,
    });

    // Original should not have ECHO
    try testing.expect(original.get("ECHO") == null);

    // Cloned should have both PING and ECHO
    try testing.expect(cloned.get("PING") != null);
    try testing.expect(cloned.get("ECHO") != null);
}
