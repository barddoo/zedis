const std = @import("std");
const Allocator = std.mem.Allocator;
const metrics = @import("metrics.zig");
const Io = std.Io;

pub const ClientConnection = struct {
    stream: Io.net.Stream,
    allocator: Allocator,
    request_count: std.atomic.Value(usize),
    connected: std.atomic.Value(bool),
    io: Io,

    pub fn init(allocator: Allocator, address: Io.net.IpAddress, io: Io) !ClientConnection {
        const stream = try address.connect(io, .{ .mode = .stream });

        // Set socket timeout to 5 seconds to prevent hanging
        const timeout = std.posix.timeval{
            .sec = 5,
            .usec = 0,
        };
        try std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        );
        try std.posix.setsockopt(
            stream.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&timeout),
        );
        return .{
            .stream = stream,
            .allocator = allocator,
            .request_count = std.atomic.Value(usize).init(0),
            .connected = std.atomic.Value(bool).init(true),
            .io = io,
        };
    }

    pub fn deinit(self: *ClientConnection) void {
        self.stream.close(self.io);
        self.connected.store(false, .monotonic);
    }

    pub fn sendCommand(self: *ClientConnection, command: []const u8) !void {
        var buffer: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &buffer);
        try w.interface.writeAll(command);
        try w.interface.flush();
        _ = self.request_count.fetchAdd(1, .monotonic);
    }

    pub fn readResponse(self: *ClientConnection, buffer: []u8) !usize {
        var read_buf: [4096]u8 = undefined;
        var r = self.stream.reader(self.io, &read_buf);
        const bytes_read = try r.interface.readSliceShort(buffer);
        if (bytes_read == 0) {
            return error.ConnectionClosed;
        }
        return bytes_read;
    }

    pub fn isConnected(self: *ClientConnection) bool {
        return self.connected.load(.monotonic);
    }
};

pub const ClientPool = struct {
    clients: []ClientConnection,
    allocator: Allocator,
    address: Io.net.IpAddress,

    pub fn init(allocator: Allocator, num_clients: usize, host: []const u8, port: u16) !ClientPool {
        const address = try Io.net.IpAddress.parse(host, port);
        const clients = try allocator.alloc(ClientConnection, num_clients);

        var threaded: Io.Threaded = .init_single_threaded;
        const io = threaded.io();

        for (clients) |*client| {
            client.* = try ClientConnection.init(allocator, address, io);
        }

        return .{
            .clients = clients,
            .allocator = allocator,
            .address = address,
        };
    }

    pub fn deinit(self: *ClientPool) void {
        for (self.clients) |*client| {
            client.deinit();
        }
        self.allocator.free(self.clients);
    }

    pub fn getClient(self: *ClientPool, index: usize) *ClientConnection {
        return &self.clients[index % self.clients.len];
    }

    pub fn totalRequests(self: *ClientPool) usize {
        var total: usize = 0;
        for (self.clients) |*client| {
            total += client.request_count.load(.monotonic);
        }
        return total;
    }
};

/// Worker thread context for running workloads
pub const WorkerContext = struct {
    client_id: usize,
    client: *ClientConnection,
    workload_fn: *const fn (client: *ClientConnection, workload_ctx: *WorkloadContext, buffer: []u8) anyerror!void,
    workload_ctx: *WorkloadContext,
    latency_tracker: *metrics.LatencyTracker,
    ops_completed: std.atomic.Value(usize),
    should_stop: *std.atomic.Value(bool),
    buffer: []u8, // Per-worker buffer to avoid race conditions
};

pub const WorkloadContext = struct {
    iterations: usize,
    current_iteration: std.atomic.Value(usize),
    start_time: std.time.Instant,
};

pub fn workerThreadFn(ctx: *WorkerContext) void {
    while (!ctx.should_stop.load(.monotonic)) {
        const iter = ctx.workload_ctx.current_iteration.fetchAdd(1, .monotonic);
        if (iter >= ctx.workload_ctx.iterations) break;

        const start = std.time.Instant.now() catch unreachable;

        ctx.workload_fn(ctx.client, ctx.workload_ctx, ctx.buffer) catch |err| {
            std.log.err("Worker {} error: {}", .{ ctx.client_id, err });
            continue;
        };

        const end = std.time.Instant.now() catch unreachable;
        const duration: u64 = end.since(start);

        ctx.latency_tracker.record(duration) catch {};
        _ = ctx.ops_completed.fetchAdd(1, .monotonic);
    }
}

/// Run a workload across multiple clients
pub fn runWorkload(
    allocator: Allocator,
    pool: *ClientPool,
    workload_fn: *const fn (client: *ClientConnection, workload_ctx: *WorkloadContext, buffer: []u8) anyerror!void,
    iterations: usize,
) !struct {
    throughput: f64,
    latency_stats: metrics.LatencyTracker.Stats,
    duration_ms: f64,
} {
    const num_clients = pool.clients.len;

    // Setup workload context
    var workload_ctx = WorkloadContext{
        .iterations = iterations,
        .current_iteration = std.atomic.Value(usize).init(0),
        .start_time = try std.time.Instant.now(),
    };

    // Allocate per-worker buffers to avoid race conditions
    const worker_buffers = try allocator.alloc([]u8, num_clients);
    defer {
        for (worker_buffers) |buf| {
            allocator.free(buf);
        }
        allocator.free(worker_buffers);
    }

    for (worker_buffers) |*buf| {
        buf.* = try allocator.alloc(u8, 4 * 1024); // 4KB buffer per worker
    }

    // Setup latency trackers (one per client to avoid contention)
    const latency_trackers = try allocator.alloc(metrics.LatencyTracker, num_clients);
    defer {
        for (latency_trackers) |*tracker| {
            tracker.deinit();
        }
        allocator.free(latency_trackers);
    }

    for (latency_trackers) |*tracker| {
        tracker.* = metrics.LatencyTracker.init(allocator);
    }

    // Setup worker contexts
    var worker_contexts = try allocator.alloc(WorkerContext, num_clients);
    defer allocator.free(worker_contexts);

    var should_stop = std.atomic.Value(bool).init(false);

    for (worker_contexts, 0..) |*worker_ctx, i| {
        worker_ctx.* = .{
            .client_id = i,
            .client = &pool.clients[i],
            .workload_fn = workload_fn,
            .workload_ctx = &workload_ctx,
            .latency_tracker = &latency_trackers[i],
            .ops_completed = std.atomic.Value(usize).init(0),
            .should_stop = &should_stop,
            .buffer = worker_buffers[i],
        };
    }

    // Spawn worker threads
    const threads = try allocator.alloc(std.Thread, num_clients);
    defer allocator.free(threads);

    const start_time = try std.time.Instant.now();

    for (threads, 0..) |*thread, i| {
        thread.* = try std.Thread.spawn(.{}, workerThreadFn, .{&worker_contexts[i]});
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    const end_time = try std.time.Instant.now();
    const duration_ns = end_time.since(start_time);
    const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

    // Merge all latency stats
    var merged_tracker = metrics.LatencyTracker.init(allocator);
    defer merged_tracker.deinit();

    for (latency_trackers) |*tracker| {
        for (tracker.samples.items) |sample| {
            try merged_tracker.record(sample);
        }
    }

    const latency_stats = try merged_tracker.calculate();

    // Calculate throughput
    var total_ops: usize = 0;
    for (worker_contexts) |*worker_ctx| {
        total_ops += worker_ctx.ops_completed.load(.monotonic);
    }

    const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;
    const throughput = @as(f64, @floatFromInt(total_ops)) / duration_s;

    return .{
        .throughput = throughput,
        .latency_stats = latency_stats,
        .duration_ms = duration_ms,
    };
}
