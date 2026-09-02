const std = @import("std");
const Store = @import("../store.zig").Store;
const KeyValueAllocator = @import("../kv_allocator.zig");
const bench_runner = @import("bench_runner.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Clock = @import("../clock.zig");

const BenchContext = struct {
    threaded: Io.Threaded,
    clock: *Clock,
    store: *Store,
    keys: [][]const u8,
    values: [][]const u8,
    allocator: Allocator,
    counter: usize = 0,

    pub fn init(allocator: Allocator, key_count: usize) !BenchContext {
        var ctx = BenchContext{
            .threaded = .init_single_threaded,
            .clock = undefined,
            .store = undefined,
            .keys = try allocator.alloc([]const u8, key_count),
            .values = try allocator.alloc([]const u8, key_count),
            .allocator = allocator,
        };
        errdefer allocator.free(ctx.keys);
        errdefer allocator.free(ctx.values);

        ctx.clock = try allocator.create(Clock);
        errdefer allocator.destroy(ctx.clock);
        ctx.clock.* = Clock.init(ctx.threaded.io(), 0);

        ctx.store = try allocator.create(Store);
        errdefer allocator.destroy(ctx.store);
        ctx.store.* = try Store.init(allocator, ctx.threaded.io(), ctx.clock, .{
            .eviction_policy = .allkeys_lru,
            .maxmemory_samples = 5,
        });
        errdefer ctx.store.deinit();

        for (ctx.keys, 0..) |*key, i| {
            key.* = try std.fmt.allocPrint(allocator, "key:{d:0>8}", .{i});
        }

        for (ctx.values, 0..) |*value, i| {
            value.* = try std.fmt.allocPrint(allocator, "value:{d:0>8}:data", .{i});
        }

        return ctx;
    }

    /// Wrapper for benchmark runner that uses default key count
    pub fn init_default(allocator: Allocator) !BenchContext {
        return init(allocator, 10_000);
    }

    pub fn init_populated(allocator: Allocator, key_count: usize) !BenchContext {
        var ctx = try init(allocator, key_count);
        errdefer ctx.deinit();

        for (ctx.keys, ctx.values) |key, value| {
            try ctx.store.set(key, value);
        }

        return ctx;
    }

    pub fn init_populated_default(allocator: Allocator) !BenchContext {
        return init_populated(allocator, 10_000);
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
        self.allocator.destroy(self.store);
        self.allocator.destroy(self.clock);
    }
};

/// Benchmark SET operations
fn bench_set(ctx: *BenchContext) !void {
    const idx = @mod(ctx.counter, ctx.keys.len);
    try ctx.store.set(ctx.keys[idx], ctx.values[idx]);
    ctx.counter += 1;
}

/// Benchmark GET operations (after pre-populating)
fn bench_get(ctx: *BenchContext) !void {
    const idx = @mod(ctx.counter, ctx.keys.len);
    _ = ctx.store.get(ctx.keys[idx]);
    ctx.counter += 1;
}

/// Benchmark mixed read-write workload (70% reads, 30% writes)
fn bench_mixed(ctx: *BenchContext) !void {
    const counter = ctx.counter;
    ctx.counter += 1;
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
fn bench_delete(ctx: *BenchContext) !void {
    const idx = @mod(ctx.counter, ctx.keys.len);
    _ = ctx.store.delete(ctx.keys[idx]);
    ctx.counter += 1;
}

/// Benchmark EXISTS operations
fn bench_exists(ctx: *BenchContext) !void {
    const idx = @mod(ctx.counter, ctx.keys.len);
    _ = ctx.store.exists(ctx.keys[idx]);
    ctx.counter += 1;
}

/// Benchmark short string operations (inline storage optimization)
fn bench_short_string(ctx: *BenchContext) !void {
    const idx = @mod(ctx.counter, ctx.keys.len);
    const short_value = "short";
    try ctx.store.set(ctx.keys[idx], short_value);
    _ = ctx.store.get(ctx.keys[idx]);
    ctx.counter += 1;
}

/// Benchmark integer operations (automatic type optimization)
fn bench_integer(ctx: *BenchContext) !void {
    const idx = @mod(ctx.counter, ctx.keys.len);
    try ctx.store.set_int(ctx.keys[idx], @as(i64, @intCast(idx)));
    _ = ctx.store.get(ctx.keys[idx]);
    ctx.counter += 1;
}

const EvictionBenchContext = struct {
    threaded: Io.Threaded,
    clock: *Clock,
    kv_allocator: *KeyValueAllocator,
    store: *Store,
    key_count: usize,
    counter: usize = 0,

    pub fn init_default(allocator: Allocator) !EvictionBenchContext {
        const key_count = 256;
        const kv_budget = 288 * 1024;

        var ctx = EvictionBenchContext{
            .threaded = .init_single_threaded,
            .clock = undefined,
            .kv_allocator = undefined,
            .store = undefined,
            .key_count = key_count,
        };

        ctx.clock = try allocator.create(Clock);
        errdefer allocator.destroy(ctx.clock);
        ctx.clock.* = Clock.init(ctx.threaded.io(), 0);
        // Leave room for entry metadata, key copies, and replacement allocations
        // while still forcing the store to evict under sustained write pressure.
        ctx.kv_allocator = try allocator.create(KeyValueAllocator);
        errdefer allocator.destroy(ctx.kv_allocator);
        ctx.kv_allocator.* = try KeyValueAllocator.init(allocator, kv_budget, .allkeys_lru);
        errdefer ctx.kv_allocator.deinit();

        ctx.store = try allocator.create(Store);
        errdefer allocator.destroy(ctx.store);
        ctx.store.* = try Store.init(ctx.kv_allocator.allocator(), ctx.threaded.io(), ctx.clock, .{
            .initial_capacity = key_count,
            .eviction_policy = .allkeys_lru,
            .maxmemory_samples = 5,
        });
        errdefer ctx.store.deinit();

        ctx.kv_allocator.attach_store(ctx.store);

        return ctx;
    }

    pub fn deinit(self: *EvictionBenchContext) void {
        const allocator = self.kv_allocator.base_allocator;
        self.store.deinit();
        allocator.destroy(self.store);
        self.kv_allocator.deinit();
        allocator.destroy(self.kv_allocator);
        allocator.destroy(self.clock);
    }
};

fn bench_eviction_pressure(ctx: *EvictionBenchContext) !void {
    const idx = @mod(ctx.counter, ctx.key_count);
    const read_idx = @mod(ctx.counter / 2, ctx.key_count);
    ctx.counter += 1;

    var key_buf: [32]u8 = undefined;
    var read_key_buf: [32]u8 = undefined;
    var value_buf: [1024]u8 = undefined;

    const key = try std.fmt.bufPrint(&key_buf, "evict-key:{d:0>4}", .{idx});
    const read_key = try std.fmt.bufPrint(&read_key_buf, "evict-key:{d:0>4}", .{read_idx});
    @memset(&value_buf, @as(u8, @truncate(idx)));

    try ctx.store.set(key, value_buf[0..]);
    _ = ctx.store.get(read_key);
}

pub fn run_all_benchmarks(allocator: Allocator) !void {
    var results: std.ArrayList(bench_runner.BenchmarkResult) = .empty;

    defer results.deinit(allocator);

    std.debug.print("\n=== Store Micro-Benchmarks ===\n\n", .{});

    // Benchmark 1: Pure SET operations
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.set (sequential)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.init_default,
            BenchContext.deinit,
            bench_set,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 2: Pure GET operations (pre-populate store first)
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.get (cached)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = false, // Already populated
            },
            BenchContext,
            BenchContext.init_populated_default,
            BenchContext.deinit,
            bench_get,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 3: Mixed workload (70% reads, 30% writes)
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.mixed (70R/30W)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.init_populated_default,
            BenchContext.deinit,
            bench_mixed,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 4: Short string optimization
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.set (short strings)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.init_default,
            BenchContext.deinit,
            bench_short_string,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 5: Integer type optimization
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.set_int (integers)",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.init_default,
            BenchContext.deinit,
            bench_integer,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 6: EXISTS operations
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.exists",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = false,
            },
            BenchContext,
            BenchContext.init_populated_default,
            BenchContext.deinit,
            bench_exists,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 7: DELETE operations
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.delete",
                .iterations = 50_000, // Increased for better accuracy
                .warmup_iterations = 5_000,
                .track_latency = true,
                .track_memory = true,
            },
            BenchContext,
            BenchContext.init_default,
            BenchContext.deinit,
            bench_delete,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Benchmark 8: Budgeted eviction pressure
    {
        const result = try bench_runner.run_benchmark_advanced(
            allocator,
            .{
                .name = "Store.eviction (budgeted)",
                .iterations = 50_000,
                .warmup_iterations = 5_000,
                .track_latency = true,
                .track_memory = false,
            },
            EvictionBenchContext,
            EvictionBenchContext.init_default,
            EvictionBenchContext.deinit,
            bench_eviction_pressure,
        );
        try results.append(allocator, result);
        bench_runner.print_result(result);
    }

    // Print summary table
    bench_runner.print_results(results.items);
}
