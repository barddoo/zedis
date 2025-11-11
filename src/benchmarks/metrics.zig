const std = @import("std");
const Allocator = std.mem.Allocator;

/// Tracks latency measurements and calculates percentiles
pub const LatencyTracker = struct {
    samples: std.ArrayList(u64),
    allocator: Allocator,

    pub fn init(allocator: Allocator) LatencyTracker {
        return .{
            .samples = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LatencyTracker) void {
        self.samples.deinit(self.allocator);
    }

    pub fn record(self: *LatencyTracker, nanoseconds: u64) !void {
        try self.samples.append(self.allocator, nanoseconds);
    }

    pub fn clear(self: *LatencyTracker) void {
        self.samples.clearRetainingCapacity();
    }

    pub const Stats = struct {
        min_ns: u64,
        max_ns: u64,
        avg_ns: u64,
        median_ns: u64,
        p95_ns: u64,
        p99_ns: u64,
        count: usize,

        pub fn format(self: Stats, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.print(
                "min={d:.2}ms avg={d:.2}ms median={d:.2}ms p95={d:.2}ms p99={d:.2}ms max={d:.2}ms (n={})",
                .{
                    @as(f64, @floatFromInt(self.min_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(self.avg_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(self.median_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(self.p95_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(self.p99_ns)) / 1_000_000.0,
                    @as(f64, @floatFromInt(self.max_ns)) / 1_000_000.0,
                    self.count,
                },
            );
        }
    };

    pub fn calculate(self: *LatencyTracker) !Stats {
        if (self.samples.items.len == 0) {
            return error.NoSamples;
        }

        // Sort samples for percentile calculation
        std.mem.sort(u64, self.samples.items, {}, std.sort.asc(u64));

        const count = self.samples.items.len;
        const min_ns = self.samples.items[0];
        const max_ns = self.samples.items[count - 1];

        // Calculate average
        var sum: u128 = 0;
        for (self.samples.items) |sample| {
            sum += sample;
        }
        const avg_ns: u64 = @intCast(sum / count);

        // Calculate percentiles
        const median_idx = count / 2;
        const p95_idx = (count * 95) / 100;
        const p99_idx = (count * 99) / 100;

        return Stats{
            .min_ns = min_ns,
            .max_ns = max_ns,
            .avg_ns = avg_ns,
            .median_ns = self.samples.items[median_idx],
            .p95_ns = self.samples.items[p95_idx],
            .p99_ns = self.samples.items[p99_idx],
            .count = count,
        };
    }
};

/// Tracks throughput over time
pub const ThroughputCounter = struct {
    operations: usize,
    start_ns: i128,
    end_ns: i128,

    pub fn init() ThroughputCounter {
        return .{
            .operations = 0,
            .start_ns = 0,
            .end_ns = 0,
        };
    }

    pub fn start(self: *ThroughputCounter) void {
        self.start_ns = std.time.nanoTimestamp();
        self.operations = 0;
    }

    pub fn recordOp(self: *ThroughputCounter) void {
        self.operations += 1;
    }

    pub fn stop(self: *ThroughputCounter) void {
        self.end_ns = std.time.nanoTimestamp();
    }

    pub fn opsPerSecond(self: ThroughputCounter) f64 {
        const duration_ns = self.end_ns - self.start_ns;
        if (duration_ns <= 0) return 0.0;
        const duration_s = @as(f64, @floatFromInt(duration_ns)) / 1_000_000_000.0;
        return @as(f64, @floatFromInt(self.operations)) / duration_s;
    }

    pub fn durationMs(self: ThroughputCounter) f64 {
        const duration_ns = self.end_ns - self.start_ns;
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    }
};

/// Captures memory usage at a point in time
pub const MemorySnapshot = struct {
    allocated_bytes: usize,
    freed_bytes: usize,
    allocations: usize,
    deallocations: usize,

    pub fn diff(before: MemorySnapshot, after: MemorySnapshot) MemoryDiff {
        return .{
            .allocated_bytes = @as(i64, @intCast(after.allocated_bytes)) - @as(i64, @intCast(before.allocated_bytes)),
            .freed_bytes = @as(i64, @intCast(after.freed_bytes)) - @as(i64, @intCast(before.freed_bytes)),
            .allocations = @as(i64, @intCast(after.allocations)) - @as(i64, @intCast(before.allocations)),
            .deallocations = @as(i64, @intCast(after.deallocations)) - @as(i64, @intCast(before.deallocations)),
        };
    }

    pub fn netBytes(self: MemorySnapshot) i64 {
        return @as(i64, @intCast(self.allocated_bytes)) - @as(i64, @intCast(self.freed_bytes));
    }
};

pub const MemoryDiff = struct {
    allocated_bytes: i64,
    freed_bytes: i64,
    allocations: i64,
    deallocations: i64,

    pub fn netBytes(self: MemoryDiff) i64 {
        return self.allocated_bytes - self.freed_bytes;
    }

    pub fn format(self: MemoryDiff, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const net = self.netBytes();
        const net_kb = @as(f64, @floatFromInt(@abs(net))) / 1024.0;
        const sign: u8 = if (net >= 0) '+' else '-';
        try writer.print(
            "{c}{d:.2}KB (allocs={}{c}, deallocs={})",
            .{ sign, net_kb, @abs(self.allocations), if (self.allocations >= 0) ' ' else 0, @abs(self.deallocations) },
        );
    }
};

/// Tracking allocator that wraps another allocator to measure memory usage
pub const TrackingAllocator = struct {
    parent_allocator: Allocator,
    allocated_bytes: std.atomic.Value(usize),
    freed_bytes: std.atomic.Value(usize),
    allocation_count: std.atomic.Value(usize),
    deallocation_count: std.atomic.Value(usize),

    pub fn init(parent: Allocator) TrackingAllocator {
        return .{
            .parent_allocator = parent,
            .allocated_bytes = std.atomic.Value(usize).init(0),
            .freed_bytes = std.atomic.Value(usize).init(0),
            .allocation_count = std.atomic.Value(usize).init(0),
            .deallocation_count = std.atomic.Value(usize).init(0),
        };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn snapshot(self: *TrackingAllocator) MemorySnapshot {
        return .{
            .allocated_bytes = self.allocated_bytes.load(.monotonic),
            .freed_bytes = self.freed_bytes.load(.monotonic),
            .allocations = self.allocation_count.load(.monotonic),
            .deallocations = self.deallocation_count.load(.monotonic),
        };
    }

    pub fn reset(self: *TrackingAllocator) void {
        self.allocated_bytes.store(0, .monotonic);
        self.freed_bytes.store(0, .monotonic);
        self.allocation_count.store(0, .monotonic);
        self.deallocation_count.store(0, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result != null) {
            _ = self.allocated_bytes.fetchAdd(len, .monotonic);
            _ = self.allocation_count.fetchAdd(1, .monotonic);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
        if (result) {
            if (new_len > buf.len) {
                _ = self.allocated_bytes.fetchAdd(new_len - buf.len, .monotonic);
            } else {
                _ = self.freed_bytes.fetchAdd(buf.len - new_len, .monotonic);
            }
        }
        return result;
    }

    fn remap(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr);
        if (result != null) {
            // Remap may relocate, so track as dealloc + alloc
            _ = self.freed_bytes.fetchAdd(buf.len, .monotonic);
            _ = self.deallocation_count.fetchAdd(1, .monotonic);
            _ = self.allocated_bytes.fetchAdd(new_len, .monotonic);
            _ = self.allocation_count.fetchAdd(1, .monotonic);
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
        _ = self.freed_bytes.fetchAdd(buf.len, .monotonic);
        _ = self.deallocation_count.fetchAdd(1, .monotonic);
    }
};

test "LatencyTracker" {
    const allocator = std.testing.allocator;
    var tracker = LatencyTracker.init(allocator);
    defer tracker.deinit();

    try tracker.record(1_000_000); // 1ms
    try tracker.record(2_000_000); // 2ms
    try tracker.record(3_000_000); // 3ms
    try tracker.record(4_000_000); // 4ms
    try tracker.record(5_000_000); // 5ms

    const stats = try tracker.calculate();
    try std.testing.expectEqual(@as(usize, 5), stats.count);
    try std.testing.expectEqual(@as(u64, 1_000_000), stats.min_ns);
    try std.testing.expectEqual(@as(u64, 5_000_000), stats.max_ns);
    try std.testing.expectEqual(@as(u64, 3_000_000), stats.avg_ns);
}

test "ThroughputCounter" {
    var counter = ThroughputCounter.init();
    counter.start();

    // Simulate some operations
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        counter.recordOp();
    }

    std.time.sleep(10 * std.time.ns_per_ms); // Sleep 10ms
    counter.stop();

    const ops_per_sec = counter.opsPerSecond();
    try std.testing.expect(ops_per_sec > 0);
    try std.testing.expect(ops_per_sec < 1_000_000); // Sanity check
}

test "TrackingAllocator" {
    var tracking = TrackingAllocator.init(std.testing.allocator);
    const allocator = tracking.allocator();

    const before = tracking.snapshot();

    const slice = try allocator.alloc(u8, 1024);
    defer allocator.free(slice);

    const after = tracking.snapshot();
    const diff = MemorySnapshot.diff(before, after);

    try std.testing.expectEqual(@as(i64, 1024), diff.allocated_bytes);
    try std.testing.expectEqual(@as(i64, 1), diff.allocations);
}
