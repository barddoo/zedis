const std = @import("std");

// Safe memory pool with allocation tracking
const Self = @This();

base_allocator: std.mem.Allocator,
pool: std.heap.MemoryPool([512]u8), // Fixed size buffers
size: usize,
allocations: std.HashMapUnmanaged(usize, *[512]u8, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),

// Stats tracking
alloc_attempts: usize = 0,
alloc_successes: usize = 0,

pub fn init(base_allocator: std.mem.Allocator, size: usize) Self {
    return .{
        .base_allocator = base_allocator,
        .pool = .init(base_allocator),
        .size = size,
        .allocations = .{},
    };
}

pub fn deinit(self: *Self) void {
    self.pool.deinit();
    self.allocations.deinit(self.base_allocator);
}

pub fn alloc(self: *Self, len: usize) ![]u8 {
    self.alloc_attempts += 1;

    if (len > self.size or len > 512) return error.TooLarge;

    const buffer = try self.pool.create();
    self.alloc_successes += 1;  // Only count if successful
    const result = buffer[0..len];

    // Track this allocation
    try self.allocations.put(self.base_allocator, @intFromPtr(result.ptr), buffer);

    return result;
}

pub fn free(self: *Self, slice: []const u8) void {
    const ptr_value = @intFromPtr(slice.ptr);
    if (self.allocations.fetchRemove(ptr_value)) |kv| {
        // Return buffer to pool
        const aligned_buffer: *align(8) [512]u8 = @alignCast(kv.value);
        self.pool.destroy(aligned_buffer);
    } else {
        // Not from this pool, use base allocator
        self.base_allocator.free(slice);
    }
}

pub fn owns(self: *Self, slice: []const u8) bool {
    return self.allocations.contains(@intFromPtr(slice.ptr));
}

pub fn getStats(self: Self) struct { attempts: usize, successes: usize, hit_rate: f64 } {
    const hit_rate = if (self.alloc_attempts > 0)
        @as(f64, @floatFromInt(self.alloc_successes)) /
        @as(f64, @floatFromInt(self.alloc_attempts))
    else
        0.0;

    return .{
        .attempts = self.alloc_attempts,
        .successes = self.alloc_successes,
        .hit_rate = hit_rate,
    };
}
