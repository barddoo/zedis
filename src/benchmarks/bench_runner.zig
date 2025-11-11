const std = @import("std");
const metrics = @import("metrics.zig");
const Allocator = std.mem.Allocator;

pub const BenchmarkResult = struct {
    name: []const u8,
    throughput: f64, // ops/sec
    latency_stats: ?metrics.LatencyTracker.Stats,
    memory_diff: ?metrics.MemoryDiff,
    duration_ms: f64,
};

pub const BenchmarkOptions = struct {
    name: []const u8,
    iterations: usize = 10_000,
    warmup_iterations: usize = 1_000,
    track_latency: bool = true,
    track_memory: bool = true,
};

/// Run a benchmark function and collect performance metrics
pub fn runBenchmark(
    allocator: Allocator,
    options: BenchmarkOptions,
    comptime benchFn: fn (allocator: Allocator) anyerror!void,
) !BenchmarkResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Warmup phase
    if (options.warmup_iterations > 0) {
        var i: usize = 0;
        while (i < options.warmup_iterations) : (i += 1) {
            try benchFn(arena_allocator);
        }
    }

    // Setup tracking
    var tracking_allocator = metrics.TrackingAllocator.init(allocator);
    var latency_tracker = metrics.LatencyTracker.init(allocator);
    defer latency_tracker.deinit();
    var throughput_counter = metrics.ThroughputCounter.init();

    const mem_before = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    // Run benchmark
    throughput_counter.start();

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();

        try benchFn(if (options.track_memory) tracking_allocator.allocator() else arena_allocator);

        if (options.track_latency) {
            const end = std.time.nanoTimestamp();
            const duration: u64 = @intCast(end - start);
            try latency_tracker.record(duration);
        }

        throughput_counter.recordOp();
    }

    throughput_counter.stop();

    const mem_after = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    return BenchmarkResult{
        .name = options.name,
        .throughput = throughput_counter.opsPerSecond(),
        .latency_stats = if (options.track_latency) try latency_tracker.calculate() else null,
        .memory_diff = if (options.track_memory) metrics.MemorySnapshot.diff(mem_before, mem_after) else null,
        .duration_ms = throughput_counter.durationMs(),
    };
}

/// Run a benchmark with custom setup/teardown and operation function
pub fn runBenchmarkAdvanced(
    allocator: Allocator,
    options: BenchmarkOptions,
    comptime Context: type,
    setupFn: fn (allocator: Allocator) anyerror!Context,
    teardownFn: fn (ctx: *Context) void,
    opFn: fn (ctx: *Context) anyerror!void,
) !BenchmarkResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Warmup phase
    if (options.warmup_iterations > 0) {
        var ctx = try setupFn(arena_allocator);
        defer teardownFn(&ctx);

        var i: usize = 0;
        while (i < options.warmup_iterations) : (i += 1) {
            try opFn(&ctx);
        }
    }

    // Setup tracking
    var tracking_allocator = metrics.TrackingAllocator.init(allocator);
    var latency_tracker = metrics.LatencyTracker.init(allocator);
    defer latency_tracker.deinit();
    var throughput_counter = metrics.ThroughputCounter.init();

    // Setup benchmark context
    var ctx = try setupFn(if (options.track_memory) tracking_allocator.allocator() else arena_allocator);
    defer teardownFn(&ctx);

    const mem_before = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    // Run benchmark
    throughput_counter.start();

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();

        try opFn(&ctx);

        if (options.track_latency) {
            const end = std.time.nanoTimestamp();
            const duration: u64 = @intCast(end - start);
            try latency_tracker.record(duration);
        }

        throughput_counter.recordOp();
    }

    throughput_counter.stop();

    const mem_after = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    return BenchmarkResult{
        .name = options.name,
        .throughput = throughput_counter.opsPerSecond(),
        .latency_stats = if (options.track_latency) try latency_tracker.calculate() else null,
        .memory_diff = if (options.track_memory) metrics.MemorySnapshot.diff(mem_before, mem_after) else null,
        .duration_ms = throughput_counter.durationMs(),
    };
}

/// Print benchmark results in a formatted table
pub fn printResults(results: []const BenchmarkResult) void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("BENCHMARK RESULTS\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    // Header
    std.debug.print("{s:<40} {s:>12} {s:>15} {s:>15}\n", .{ "Benchmark", "Ops/sec", "Avg Latency", "Memory" });
    std.debug.print("-" ** 100 ++ "\n", .{});

    // Results
    for (results) |result| {
        const avg_latency_ms = if (result.latency_stats) |stats|
            @as(f64, @floatFromInt(stats.avg_ns)) / 1_000_000.0
        else
            0.0;

        const mem_kb = if (result.memory_diff) |diff|
            @as(f64, @floatFromInt(@abs(diff.netBytes()))) / 1024.0
        else
            0.0;

        const mem_sign = if (result.memory_diff) |diff|
            if (diff.netBytes() >= 0) "+" else "-"
        else
            " ";

        std.debug.print("{s:<40} {d:>12.0} {d:>13.3}ms {s}{d:>13.2}KB\n", .{
            result.name,
            result.throughput,
            avg_latency_ms,
            mem_sign,
            mem_kb,
        });
    }

    std.debug.print("\n", .{});
    std.debug.print("Detailed Statistics:\n", .{});
    std.debug.print("-" ** 100 ++ "\n", .{});

    for (results) |result| {
        std.debug.print("\n{s}:\n", .{result.name});
        std.debug.print("  Duration: {d:.2}ms\n", .{result.duration_ms});
        std.debug.print("  Throughput: {d:.0} ops/sec\n", .{result.throughput});

        if (result.latency_stats) |stats| {
            std.debug.print("  Latency: min={d:.2}ms avg={d:.2}ms median={d:.2}ms p95={d:.2}ms p99={d:.2}ms max={d:.2}ms\n", .{
                @as(f64, @floatFromInt(stats.min_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(stats.avg_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(stats.median_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(stats.p95_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(stats.p99_ns)) / 1_000_000.0,
                @as(f64, @floatFromInt(stats.max_ns)) / 1_000_000.0,
            });
        }

        if (result.memory_diff) |diff| {
            const net = diff.netBytes();
            const net_kb = @as(f64, @floatFromInt(@abs(net))) / 1024.0;
            const sign: u8 = if (net >= 0) '+' else '-';
            std.debug.print("  Memory: {c}{d:.2}KB\n", .{ sign, net_kb });
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
}

/// Print a single result immediately (for interactive benchmarks)
pub fn printResult(result: BenchmarkResult) void {
    std.debug.print("{s}: {d:.0} ops/sec", .{ result.name, result.throughput });

    if (result.latency_stats) |stats| {
        const avg_ms = @as(f64, @floatFromInt(stats.avg_ns)) / 1_000_000.0;
        std.debug.print(", avg={d:.3}ms", .{avg_ms});
    }

    if (result.memory_diff) |diff| {
        const net_kb = @as(f64, @floatFromInt(@abs(diff.netBytes()))) / 1024.0;
        const sign = if (diff.netBytes() >= 0) "+" else "-";
        std.debug.print(", mem={s}{d:.2}KB", .{ sign, net_kb });
    }

    std.debug.print("\n", .{});
}

test "runBenchmark basic" {
    const allocator = std.testing.allocator;

    const TestBench = struct {
        fn bench(alloc: Allocator) !void {
            const slice = try alloc.alloc(u8, 100);
            defer alloc.free(slice);
            @memset(slice, 42);
        }
    };

    const result = try runBenchmark(allocator, .{
        .name = "test_benchmark",
        .iterations = 100,
        .warmup_iterations = 10,
    }, TestBench.bench);

    try std.testing.expect(result.throughput > 0);
    try std.testing.expect(result.latency_stats != null);
    try std.testing.expect(result.memory_diff != null);
}
