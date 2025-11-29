const std = @import("std");
const Store = @import("../store.zig").Store;
const bench_runner = @import("bench_runner.zig");
const Allocator = std.mem.Allocator;

const BenchContext = struct {
    store: Store,
    keys: [][]const u8,
    values: [][]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, key_count: usize) !BenchContext {
        const store = Store.init(allocator, 8192);

        // Pre-generate keys and values
        const keys = try allocator.alloc([]const u8, key_count);
        const values = try allocator.alloc([]const u8, key_count);

        for (keys, 0..) |*key, i| {
            key.* = try std.fmt.allocPrint(allocator, "key:{d:0>8}", .{i});
        }

        for (values, 0..) |*value, i| {
            value.* = try std.fmt.allocPrint(allocator, "value:{d:0>8}:data", .{i});
        }

        return .{
            .store = store,
            .keys = keys,
            .values = values,
            .allocator = allocator,
        };
    }

    /// Wrapper for benchmark runner that uses default key count
    pub fn initDefault(allocator: Allocator) !BenchContext {
        return init(allocator, 10_000);
    }

    pub fn deinit(self: *BenchContext) void {
        for (self.keys) |key| {
            self.allocator.free(key);
        }
        for (self.values) |value| {
            self.allocator.free(value);
        }
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
        self.store.deinit();
    }
};

/// Benchmark SET operations
fn benchSet(ctx: *BenchContext) !void {
    const idx = @mod(ctx.store.access_counter.load(.monotonic), ctx.keys.len);
    try ctx.store.set(ctx.keys[idx], ctx.values[idx]);
    _ = ctx.store.access_counter.fetchAdd(1, .monotonic);
}

/// Benchmark GET operations (after pre-populating)
fn benchGet(ctx: *BenchContext) !void {
    const idx = @mod(ctx.store.access_counter.load(.monotonic), ctx.keys.len);
    _ = ctx.store.get(ctx.keys[idx]);
    _ = ctx.store.access_counter.fetchAdd(1, .monotonic);
}

/// Benchmark mixed read-write workload (70% reads, 30% writes)
fn benchMixed(ctx: *BenchContext) !void {
    const counter = ctx.store.access_counter.fetchAdd(1, .monotonic);
    const idx = @mod(counter, ctx.keys.len);

    if (@mod(counter, 10) < 7) {
        // 70% reads
        _ = ctx.store.get(ctx.keys[idx]);
    } else {
        // 30% writes
        try ctx.store.set(ctx.keys[idx], ctx.values[idx]);
    }
}

/// Benchmark DELETE operations
fn benchDelete(ctx: *BenchContext) !void {
    const idx = @mod(ctx.store.access_counter.load(.monotonic), ctx.keys.len);
    _ = ctx.store.delete(ctx.keys[idx]);
    _ = ctx.store.access_counter.fetchAdd(1, .monotonic);
}

/// Benchmark EXISTS operations
fn benchExists(ctx: *BenchContext) !void {
    const idx = @mod(ctx.store.access_counter.load(.monotonic), ctx.keys.len);
    _ = ctx.store.exists(ctx.keys[idx]);
    _ = ctx.store.access_counter.fetchAdd(1, .monotonic);
}

/// Benchmark short string operations (inline storage optimization)
fn benchShortString(ctx: *BenchContext) !void {
    const idx = @mod(ctx.store.access_counter.load(.monotonic), ctx.keys.len);
    const short_value = "short";
    try ctx.store.set(ctx.keys[idx], short_value);
    _ = ctx.store.get(ctx.keys[idx]);
    _ = ctx.store.access_counter.fetchAdd(1, .monotonic);
}

/// Benchmark integer operations (automatic type optimization)
fn benchInteger(ctx: *BenchContext) !void {
    const idx = @mod(ctx.store.access_counter.load(.monotonic), ctx.keys.len);
    try ctx.store.setInt(ctx.keys[idx], @as(i64, @intCast(idx)));
    _ = ctx.store.get(ctx.keys[idx]);
    _ = ctx.store.access_counter.fetchAdd(1, .monotonic);
}

pub fn runAllBenchmarks(allocator: Allocator) !void {
    var results: std.ArrayList(bench_runner.BenchmarkResult) = .empty;

    defer results.deinit(allocator);

    std.debug.print("\n=== Store Micro-Benchmarks ===\n\n", .{});

    // Benchmark 1: Pure SET operations
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.set (sequential)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchSet,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 2: Pure GET operations (pre-populate store first)
    {
        var ctx = try BenchContext.init(allocator, 10_000);
        defer ctx.deinit();

        // Pre-populate with data
        for (ctx.keys, ctx.values) |key, value| {
            try ctx.store.set(key, value);
        }

        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.get (cached)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = false, // Already populated
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchGet,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 3: Mixed workload (70% reads, 30% writes)
    {
        var ctx = try BenchContext.init(allocator, 10_000);
        defer ctx.deinit();

        // Pre-populate with data
        for (ctx.keys, ctx.values) |key, value| {
            try ctx.store.set(key, value);
        }

        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.mixed (70R/30W)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchMixed,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 4: Short string optimization
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.set (short strings)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchShortString,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 5: Integer type optimization
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.setInt (integers)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchInteger,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 6: EXISTS operations
    {
        var ctx = try BenchContext.init(allocator, 10_000);
        defer ctx.deinit();

        // Pre-populate with data
        for (ctx.keys, ctx.values) |key, value| {
            try ctx.store.set(key, value);
        }

        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.exists",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = false,
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchExists,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 7: DELETE operations
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Store.delete",
                .iterations = 50_000, // Increased for better accuracy
                .warmup_iterations = 5_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.initDefault,
            BenchContext.deinit,
            benchDelete,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Print summary table
    bench_runner.printResults(results.items);
}
