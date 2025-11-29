const std = @import("std");
const Store = @import("../store.zig").Store;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;
const initRegistry = @import("../commands/init.zig").initRegistry;
const parser = @import("../parser.zig");
const Value = parser.Value;
const bench_runner = @import("bench_runner.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Client = @import("../client.zig").Client;
const aof = @import("../aof/aof.zig");

const CommandBenchContext = struct {
    store: Store,
    registry: CommandRegistry,
    allocator: Allocator,
    buffer: []u8,
    writer_buffer: std.io.FixedBufferStream([]u8),
    writer_impl: std.io.FixedBufferStream([]u8).Writer,
    writer: std.Io.Writer,
    client: Client,
    aof_writer: aof.Writer,
    counter: std.atomic.Value(usize),

    pub fn init(allocator: Allocator) !CommandBenchContext {
        const store = Store.init(allocator, 8192);
        const registry = try initRegistry(allocator);

        // Create a discarding writer for benchmarking (we don't need output)
        const buffer = try allocator.alloc(u8, 1024 * 1024); // 1MB buffer
        var writer_buffer = std.io.fixedBufferStream(buffer);
        const writer_impl = writer_buffer.writer();

        // Use discarding writer for benchmarking
        const discarding = std.Io.Writer.Discarding.init(&.{});
        const writer = discarding.writer;

        // Create dummy client and AOF writer for benchmarking
        var dummy_client: Client = undefined;
        dummy_client.authenticated = true;
        var aof_writer: aof.Writer = undefined;
        aof_writer.enabled = false; // Disable AOF for benchmarking

        return .{
            .store = store,
            .registry = registry,
            .allocator = allocator,
            .buffer = buffer,
            .writer_buffer = writer_buffer,
            .writer_impl = writer_impl,
            .writer = writer,
            .client = dummy_client,
            .aof_writer = aof_writer,
            .counter = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *CommandBenchContext) void {
        self.registry.deinit();
        self.store.deinit();
        self.allocator.free(self.buffer);
    }

    pub fn resetWriter(self: *CommandBenchContext) void {
        self.writer_buffer.reset();
    }
};

/// Benchmark SET command
fn benchCommandSet(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    var val_buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{counter});
    const value = try std.fmt.bufPrint(&val_buf, "value:{d}:data", .{counter});

    var args = [_]Value{
        .{ .data = "SET" },
        .{ .data = key },
        .{ .data = value },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark GET command (with pre-populated data)
fn benchCommandGet(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{@mod(counter, 10000)});

    var args = [_]Value{
        .{ .data = "GET" },
        .{ .data = key },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark INCR command
fn benchCommandIncr(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "counter:{d}", .{@mod(counter, 100)});

    var args = [_]Value{
        .{ .data = "INCR" },
        .{ .data = key },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark DEL command
fn benchCommandDel(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{counter});

    // Set it first
    try ctx.store.set(key, "value");

    var args = [_]Value{
        .{ .data = "DEL" },
        .{ .data = key },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark EXISTS command
fn benchCommandExists(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{@mod(counter, 10000)});

    var args = [_]Value{
        .{ .data = "EXISTS" },
        .{ .data = key },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark LPUSH command
fn benchCommandLpush(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    var val_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "list:{d}", .{@mod(counter, 100)});
    const value = try std.fmt.bufPrint(&val_buf, "item:{d}", .{counter});

    var args = [_]Value{
        .{ .data = "LPUSH" },
        .{ .data = key },
        .{ .data = value },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark LRANGE command
fn benchCommandLrange(ctx: *CommandBenchContext) !void {
    ctx.resetWriter();
    const counter = ctx.counter.fetchAdd(1, .monotonic);
    var key_buf: [32]u8 = undefined;
    const key = try std.fmt.bufPrint(&key_buf, "list:{d}", .{@mod(counter, 100)});

    var args = [_]Value{
        .{ .data = "LRANGE" },
        .{ .data = key },
        .{ .data = "0" },
        .{ .data = "10" },
    };

    try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
}

/// Benchmark RESP parsing
fn benchRespParsing(allocator: Allocator) !void {
    const input = "*3\r\n$3\r\nSET\r\n$4\r\nkey1\r\n$6\r\nvalue1\r\n";
    var reader = std.Io.Reader.fixed(input);
    var p = parser.Parser.init(allocator);
    var cmd = try p.parse(&reader);
    cmd.deinit();
}

pub fn runAllBenchmarks(allocator: Allocator) !void {
    var results: std.ArrayList(bench_runner.BenchmarkResult) = .empty;
    defer results.deinit(allocator);

    std.debug.print("\n=== Command Benchmarks ===\n\n", .{});

    // Benchmark 1: SET command
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: SET",
                .iterations = 200_000,
                .warmup_iterations = 20_000,
                .track_latency = true,
                .track_memory = true,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandSet,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 2: GET command (pre-populate first)
    {
        var ctx = try CommandBenchContext.init(allocator);
        defer ctx.deinit();

        // Pre-populate data
        var i: usize = 0;
        while (i < 10_000) : (i += 1) {
            var key_buf: [32]u8 = undefined;
            var val_buf: [64]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{i});
            const value = try std.fmt.bufPrint(&val_buf, "value:{d}:data", .{i});
            try ctx.store.set(key, value);
        }

        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: GET (cached)",
                .iterations = 200_000,
                .warmup_iterations = 20_000,
                .track_latency = true,
                .track_memory = false,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandGet,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 3: INCR command
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: INCR",
                .iterations = 200_000,
                .warmup_iterations = 20_000,
                .track_latency = true,
                .track_memory = true,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandIncr,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 4: DEL command
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: DEL",
                .iterations = 100_000,
                .warmup_iterations = 10_000,
                .track_latency = true,
                .track_memory = true,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandDel,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 5: EXISTS command
    {
        var ctx = try CommandBenchContext.init(allocator);
        defer ctx.deinit();

        // Pre-populate data
        var i: usize = 0;
        while (i < 10_000) : (i += 1) {
            var key_buf: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&key_buf, "key:{d}", .{i});
            try ctx.store.set(key, "value");
        }

        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: EXISTS",
                .iterations = 200_000,
                .warmup_iterations = 20_000,
                .track_latency = true,
                .track_memory = false,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandExists,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 6: LPUSH command
    {
        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: LPUSH",
                .iterations = 200_000,
                .warmup_iterations = 20_000,
                .track_latency = true,
                .track_memory = true,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandLpush,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 7: LRANGE command (with pre-populated lists)
    {
        var ctx = try CommandBenchContext.init(allocator);
        defer ctx.deinit();

        // Pre-populate lists
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            var j: usize = 0;
            while (j < 50) : (j += 1) {
                var key_buf: [32]u8 = undefined;
                var val_buf: [32]u8 = undefined;
                const key = try std.fmt.bufPrint(&key_buf, "list:{d}", .{i});
                const value = try std.fmt.bufPrint(&val_buf, "item:{d}", .{j});

                var args = [_]Value{
                    .{ .data = "LPUSH" },
                    .{ .data = key },
                    .{ .data = value },
                };
                ctx.resetWriter();
                try ctx.registry.executeCommand(&ctx.writer, &ctx.client, &ctx.store, &ctx.aof_writer, &args);
            }
        }

        const result = try bench_runner.runBenchmarkAdvanced(
            allocator,
            .{
                .name = "Command: LRANGE",
                .iterations = 200_000,
                .warmup_iterations = 20_000,
                .track_latency = true,
                .track_memory = false,
            },
            CommandBenchContext,
            CommandBenchContext.init,
            CommandBenchContext.deinit,
            benchCommandLrange,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Benchmark 8: RESP parsing
    {
        const result = try bench_runner.runBenchmark(
            allocator,
            .{
                .name = "RESP Parsing",
                .iterations = 500_000,
                .warmup_iterations = 50_000,
                .track_latency = true,
                .track_memory = true,
            },
            benchRespParsing,
        );
        try results.append(allocator, result);
        bench_runner.printResult(result);
    }

    // Print summary table
    bench_runner.printResults(results.items);
}
