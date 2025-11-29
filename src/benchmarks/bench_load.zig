const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const bench_runner = @import("bench_runner.zig");
const metrics = @import("metrics.zig");
const client_pool = @import("client_pool.zig");
const ClientConnection = client_pool.ClientConnection;
const ClientPool = client_pool.ClientPool;
const WorkloadContext = client_pool.WorkloadContext;

/// RESP protocol helper to build commands
pub fn buildRespCommand(buffer: []u8, parts: []const []const u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();

    // Write array length
    try writer.print("*{d}\r\n", .{parts.len});

    // Write each part as bulk string
    for (parts) |part| {
        try writer.print("${d}\r\n{s}\r\n", .{ part.len, part });
    }

    return stream.getWritten();
}

/// Workload: Write-heavy (90% SET, 10% GET)
fn workloadWriteHeavy(client: *ClientConnection, ctx: *WorkloadContext, buffer: []u8) !void {
    const iter = ctx.current_iteration.load(.monotonic);
    const is_write = (@mod(iter, 10) < 9);

    var key_buf: [32]u8 = undefined;
    var val_buf: [64]u8 = undefined;

    if (is_write) {
        // SET operation
        const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{iter});
        const value = try std.fmt.bufPrint(&val_buf, "value:{d}:data", .{iter});

        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "SET", key, value });
        try client.sendCommand(cmd);
    } else {
        // GET operation
        const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{iter -| 10});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "GET", key });
        try client.sendCommand(cmd);
    }

    // Read response
    var response_buf: [1024]u8 = undefined;
    _ = try client.readResponse(&response_buf);
}

/// Workload: Read-heavy (90% GET, 10% SET)
fn workloadReadHeavy(client: *ClientConnection, ctx: *WorkloadContext, buffer: []u8) !void {
    const iter = ctx.current_iteration.load(.monotonic);
    const is_read = (@mod(iter, 10) < 9);

    var key_buf: [32]u8 = undefined;
    var val_buf: [64]u8 = undefined;

    if (is_read) {
        // GET operation
        const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{@mod(iter, 10000)});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "GET", key });
        try client.sendCommand(cmd);
    } else {
        // SET operation
        const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{iter});
        const value = try std.fmt.bufPrint(&val_buf, "value:{d}:data", .{iter});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "SET", key, value });
        try client.sendCommand(cmd);
    }

    // Read response
    var response_buf: [1024]u8 = undefined;
    _ = try client.readResponse(&response_buf);
}

/// Workload: Mixed (70% GET, 30% SET)
fn workloadMixed(client: *ClientConnection, ctx: *WorkloadContext, buffer: []u8) !void {
    const iter = ctx.current_iteration.load(.monotonic);
    const is_read = (@mod(iter, 10) < 7);

    var key_buf: [32]u8 = undefined;
    var val_buf: [64]u8 = undefined;

    if (is_read) {
        // GET operation
        const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{@mod(iter, 10000)});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "GET", key });
        try client.sendCommand(cmd);
    } else {
        // SET operation
        const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{iter});
        const value = try std.fmt.bufPrint(&val_buf, "value:{d}:data", .{iter});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "SET", key, value });
        try client.sendCommand(cmd);
    }

    // Read response
    var response_buf: [1024]u8 = undefined;
    _ = try client.readResponse(&response_buf);
}

/// Workload: List operations (LPUSH/LRANGE)
fn workloadLists(client: *ClientConnection, ctx: *WorkloadContext, buffer: []u8) !void {
    const iter = ctx.current_iteration.load(.monotonic);
    const is_push = (@mod(iter, 10) < 7);

    var key_buf: [32]u8 = undefined;
    var val_buf: [64]u8 = undefined;

    if (is_push) {
        // LPUSH operation
        const key = try std.fmt.bufPrint(&key_buf, "list:{d}", .{@mod(iter, 100)});
        const value = try std.fmt.bufPrint(&val_buf, "item:{d}", .{iter});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "LPUSH", key, value });
        try client.sendCommand(cmd);
    } else {
        // LRANGE operation
        const key = try std.fmt.bufPrint(&key_buf, "list:{d}", .{@mod(iter, 100)});
        const cmd = try buildRespCommand(buffer, &[_][]const u8{ "LRANGE", key, "0", "10" });
        try client.sendCommand(cmd);
    }

    // Read response
    var response_buf: [4096]u8 = undefined;
    _ = try client.readResponse(&response_buf);
}

/// Workload: Counter increments (INCR)
fn workloadCounters(client: *ClientConnection, ctx: *WorkloadContext, buffer: []u8) !void {
    const iter = ctx.current_iteration.load(.monotonic);
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "counter:{d}", .{@mod(iter, 100)});

    const cmd = try buildRespCommand(buffer, &[_][]const u8{ "INCR", key });
    try client.sendCommand(cmd);

    // Read response
    var response_buf: [1024]u8 = undefined;
    _ = try client.readResponse(&response_buf);
}

pub const LoadTestConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    num_clients: usize = 10,
    operations: usize = 10_000,
};

pub fn runLoadTest(
    allocator: Allocator,
    config: LoadTestConfig,
    workload_name: []const u8,
    workload_fn: *const fn (client: *ClientConnection, workload_ctx: *WorkloadContext, buffer: []u8) anyerror!void,
) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("\n--- Load Test: {s} ---\n", .{workload_name});
    try stdout.print("Clients: {d}, Operations: {d}\n", .{ config.num_clients, config.operations });

    // Wait a bit to ensure server is ready
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Create client pool
    var pool = try ClientPool.init(allocator, config.num_clients, config.host, config.port);
    defer pool.deinit();

    // Run workload
    const start_time = std.time.nanoTimestamp();
    const result = try client_pool.runWorkload(allocator, &pool, workload_fn, config.operations);
    const end_time = std.time.nanoTimestamp();

    const duration_s = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000_000.0;

    // Print results
    try stdout.print("Duration: {d:.2}s\n", .{duration_s});
    try stdout.print("Throughput: {d:.0} ops/sec\n", .{result.throughput});
    try stdout.print("Latency: {any}\n", .{result.latency_stats});
    try stdout.print("Total requests: {d}\n\n", .{pool.totalRequests()});
}

pub fn runAllLoadTests(allocator: Allocator) !void {
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\n");
    try stdout.writeAll("=" ** 100);
    try stdout.writeAll("\n");
    try stdout.writeAll("INTEGRATION LOAD TESTS\n");
    try stdout.writeAll("=" ** 100);
    try stdout.writeAll("\n");
    try stdout.writeAll("NOTE: These tests require a running Zedis server at 127.0.0.1:6379\n");
    try stdout.writeAll("Start the server with: zig build run\n");
    try stdout.writeAll("=" ** 100);
    try stdout.writeAll("\n\n");

    // Check if stdin is a terminal (interactive mode)
    const stdin_file = std.fs.File.stdin();
    const is_terminal = stdin_file.isTty();

    if (is_terminal) {
        try stdout.writeAll("Press Enter to start tests (or Ctrl+C to cancel)...");
        var stdin_buf: [1]u8 = undefined;
        _ = try stdin_file.read(&stdin_buf);
    } else {
        try stdout.writeAll("Starting tests in 2 seconds...\n");
        std.Thread.sleep(2 * std.time.ns_per_s);
    }

    const configs = [_]LoadTestConfig{
        .{ .num_clients = 10, .operations = 10_000 },
        .{ .num_clients = 50, .operations = 50_000 },
        .{ .num_clients = 100, .operations = 100_000 },
    };

    // Test each workload with different client counts
    for (configs) |config| {
        try stdout.print("\n### Configuration: {d} clients, {d} operations ###\n", .{ config.num_clients, config.operations });

        try runLoadTest(allocator, config, "Write-Heavy (90W/10R)", workloadWriteHeavy);
        try runLoadTest(allocator, config, "Read-Heavy (90R/10W)", workloadReadHeavy);
        try runLoadTest(allocator, config, "Mixed (70R/30W)", workloadMixed);
        try runLoadTest(allocator, config, "List Operations", workloadLists);
        try runLoadTest(allocator, config, "Counter Increments", workloadCounters);
    }

    try stdout.writeAll("\n");
    try stdout.writeAll("=" ** 100);
    try stdout.writeAll("\nAll load tests completed!\n");
    try stdout.writeAll("=" ** 100);
    try stdout.writeAll("\n");
}
