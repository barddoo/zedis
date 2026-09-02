const std = @import("std");
const metrics = @import("metrics.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

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
pub fn run_benchmark(
    allocator: Allocator,
    options: BenchmarkOptions,
    comptime benchFn: fn (allocator: Allocator) anyerror!void,
) !BenchmarkResult {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Warmup phase
    if (options.warmup_iterations > 0) {
        var i: usize = 0;
        while (i < options.warmup_iterations) : (i += 1) {
            try benchFn(allocator);
        }
    }

    // Setup tracking
    var tracking_allocator = metrics.TrackingAllocator.init(allocator);
    var latency_tracker = metrics.LatencyTracker.init(allocator);
    defer latency_tracker.deinit();
    var throughput_counter = metrics.ThroughputCounter.init(io);

    const mem_before = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    // Run benchmark
    throughput_counter.start();

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        const start = Io.Clock.awake.now(io);

        try benchFn(if (options.track_memory) tracking_allocator.allocator() else allocator);

        if (options.track_latency) {
            const end = Io.Clock.awake.now(io);
            const duration: u64 = @intCast(start.durationTo(end).toNanoseconds());
            try latency_tracker.record(duration);
        }

        throughput_counter.record_op();
    }

    throughput_counter.stop();

    const mem_after = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    return BenchmarkResult{
        .name = options.name,
        .throughput = throughput_counter.ops_per_second(),
        .latency_stats = if (options.track_latency) try latency_tracker.calculate() else null,
        .memory_diff = if (options.track_memory) metrics.MemorySnapshot.diff(mem_before, mem_after) else null,
        .duration_ms = throughput_counter.duration_ms(),
    };
}

/// Run a benchmark with custom setup/teardown and operation function
pub fn run_benchmark_advanced(
    allocator: Allocator,
    options: BenchmarkOptions,
    comptime Context: type,
    setup_fn: fn (allocator: Allocator) anyerror!Context,
    teardown_fn: fn (ctx: *Context) void,
    op_fn: fn (ctx: *Context) anyerror!void,
) !BenchmarkResult {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Warmup phase
    if (options.warmup_iterations > 0) {
        var ctx = try setup_fn(allocator);
        defer teardown_fn(&ctx);

        var i: usize = 0;
        while (i < options.warmup_iterations) : (i += 1) {
            try op_fn(&ctx);
        }
    }

    // Setup tracking
    var tracking_allocator = metrics.TrackingAllocator.init(allocator);
    var latency_tracker = metrics.LatencyTracker.init(allocator);
    defer latency_tracker.deinit();
    var throughput_counter = metrics.ThroughputCounter.init(io);

    // Setup benchmark context
    var ctx = try setup_fn(if (options.track_memory) tracking_allocator.allocator() else allocator);
    defer teardown_fn(&ctx);

    const mem_before = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    // Run benchmark
    throughput_counter.start();

    var i: usize = 0;
    while (i < options.iterations) : (i += 1) {
        const start = Io.Clock.awake.now(io);

        try op_fn(&ctx);

        if (options.track_latency) {
            const end = Io.Clock.awake.now(io);
            const duration: u64 = @intCast(start.durationTo(end).toNanoseconds());
            try latency_tracker.record(duration);
        }

        throughput_counter.record_op();
    }

    throughput_counter.stop();

    const mem_after = if (options.track_memory) tracking_allocator.snapshot() else undefined;

    return BenchmarkResult{
        .name = options.name,
        .throughput = throughput_counter.ops_per_second(),
        .latency_stats = if (options.track_latency) try latency_tracker.calculate() else null,
        .memory_diff = if (options.track_memory) metrics.MemorySnapshot.diff(mem_before, mem_after) else null,
        .duration_ms = throughput_counter.duration_ms(),
    };
}

/// Print benchmark results in a formatted table
pub fn print_results(results: []const BenchmarkResult) void {
    std.debug.print("\n", .{});
    std.debug.print("=" ** 110 ++ "\n", .{});
    std.debug.print("BENCHMARK SUMMARY\n", .{});
    std.debug.print("=" ** 110 ++ "\n\n", .{});

    // Header
    std.debug.print("{s:<42} {s:>15} {s:>12} {s:>12} {s:>18}\n", .{ "Benchmark", "Throughput", "p50", "p99", "Memory (net)" });
    std.debug.print("-" ** 110 ++ "\n", .{});

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

        std.debug.print("{s:<42} {d:>12.0} ops/s {d:>9.1}µs {d:>9.1}µs", .{
            result.name,
            result.throughput,
            median_us,
            p99_us,
        });

        if (result.memory_diff) |mem| {
            const net = mem.net_bytes();
            const net_kb = @as(f64, @floatFromInt(@abs(net))) / 1024.0;
            const sign: u8 = if (net >= 0) '+' else '-';
            std.debug.print(" {c}{d:>10.2} KB\n", .{ sign, net_kb });
        } else {
            std.debug.print(" {s:>18}\n", .{"N/A"});
        }
    }

    std.debug.print("\n" ++ "=" ** 110 ++ "\n", .{});
}

/// Print a single result immediately (for interactive benchmarks)
pub fn print_result(result: BenchmarkResult) void {
    std.debug.print("{s}: {d:.0} ops/s", .{ result.name, result.throughput });

    if (result.latency_stats) |stats| {
        const p50_us = @as(f64, @floatFromInt(stats.median_ns)) / 1_000.0;
        const p99_us = @as(f64, @floatFromInt(stats.p99_ns)) / 1_000.0;
        std.debug.print(" | p50={d:.1}µs p99={d:.1}µs", .{ p50_us, p99_us });
    }

    if (result.memory_diff) |mem| {
        const net = mem.net_bytes();
        const net_kb = @as(f64, @floatFromInt(@abs(net))) / 1024.0;
        const sign: u8 = if (net >= 0) '+' else '-';
        std.debug.print(" | mem={c}{d:.2}KB", .{ sign, net_kb });
    }

    std.debug.print("\n", .{});
}

test "run_benchmark basic" {
    const allocator = std.testing.allocator;

    const TestBench = struct {
        fn bench(alloc: Allocator) !void {
            const slice = try alloc.alloc(u8, 100);
            defer alloc.free(slice);
            @memset(slice, 42);
        }
    };

    const result = try run_benchmark(allocator, .{
        .name = "test_benchmark",
        .iterations = 100,
        .warmup_iterations = 10,
    }, TestBench.bench);

    try std.testing.expect(result.throughput > 0);
    try std.testing.expect(result.latency_stats != null);
    try std.testing.expect(result.memory_diff != null);
}
