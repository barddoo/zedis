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
    std.debug.print("=" ** 90 ++ "\n", .{});
    std.debug.print("BENCHMARK SUMMARY\n", .{});
    std.debug.print("=" ** 90 ++ "\n\n", .{});

    // Header
    std.debug.print("{s:<42} {s:>15} {s:>12} {s:>12}\n", .{ "Benchmark", "Throughput", "p50", "p99" });
    std.debug.print("-" ** 90 ++ "\n", .{});

    // Results
    for (results) |result| {
        const median_us = if (result.latency_stats) |stats|
            @as(f64, @floatFromInt(stats.median_ns)) / 1_000.0
        else
            0.0;

        const p99_us = if (result.latency_stats) |stats|
            @as(f64, @floatFromInt(stats.p99_ns)) / 1_000.0
        else
            0.0;

        std.debug.print("{s:<42} {d:>12.0} ops/s {d:>9.1}µs {d:>9.1}µs\n", .{
            result.name,
            result.throughput,
            median_us,
            p99_us,
        });
    }

    std.debug.print("\n" ++ "=" ** 90 ++ "\n", .{});
}

/// Print a single result immediately (for interactive benchmarks)
pub fn printResult(result: BenchmarkResult) void {
    std.debug.print("{s}: {d:.0} ops/s", .{ result.name, result.throughput });

    if (result.latency_stats) |stats| {
        const p50_us = @as(f64, @floatFromInt(stats.median_ns)) / 1_000.0;
        const p99_us = @as(f64, @floatFromInt(stats.p99_ns)) / 1_000.0;
        std.debug.print(" | p50={d:.1}µs p99={d:.1}µs", .{ p50_us, p99_us });
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
