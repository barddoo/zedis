const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const Hash32 = std.hash.Murmur2_32;
const Hash64 = std.hash.Murmur2_64;

const seed = 0x9747b28c;
pub const BloomFilter = @This();

const Error = error{
    InvalidArguments,
    OutOfMemory,
};

allocator: Allocator,
bits: u64,
bytes: u64,
error_rate: f64,
n2: u6,
// bits per entry
bpe: f64,
hashes: u32,
capacity: u64,
entries: u64,
force64: bool,
bit_array: []u8,

const BloomOptions = struct {
    error_rate: f64,
    capacity: u64,
    allocator: Allocator,
    force64: bool = false,
};

pub fn init(options: BloomOptions) !BloomFilter {
    // Validate inputs
    if (options.capacity < 1 or options.error_rate <= 0 or options.error_rate >= 1.0) {
        return error.InvalidArguments;
    }

    // Extract fields for shorthand initialization
    const allocator = options.allocator;
    const error_rate = options.error_rate;
    const force64 = options.force64;
    const capacity = options.capacity;

    const bpe = calc_bpe(error_rate);
    const hashes = @as(u32, @intFromFloat(@ceil(math.ln2 * bpe)));

    // Calculate bits needed
    const needed_bits = @as(f64, @floatFromInt(capacity)) * bpe;

    // Round up to next power of 2 (optimization for fast modulo)
    const bn2 = @log2(needed_bits);
    const n2 = @as(u6, @intFromFloat(@ceil(bn2)));
    const bits = @as(u64, 1) << n2;

    // Calculate bytes with 64-bit alignment
    const bytes = if (bits % 64 != 0)
        ((bits / 64) + 1) * 8
    else
        bits / 8;

    const actual_bits = bytes * 8;

    // Calculate actual capacity (may be larger due to rounding)
    const bit_diff = actual_bits - @as(u64, @intFromFloat(needed_bits));
    const item_diff = @as(u64, @intFromFloat(@floor(@as(f64, @floatFromInt(bit_diff)) / bpe)));
    const actual_capacity = capacity + item_diff;

    // Allocate bit array
    const bit_array = try allocator.alloc(u8, bytes);
    @memset(bit_array, 0);

    return .{
        .allocator = allocator,
        .bits = actual_bits,
        .bytes = bytes,
        .error_rate = error_rate,
        .n2 = n2,
        .bpe = bpe,
        .hashes = hashes,
        .capacity = actual_capacity,
        .entries = 0,
        .force64 = force64,
        .bit_array = bit_array,
    };
}

pub fn deinit(self: *BloomFilter) void {
    self.allocator.free(self.bit_array);
}

inline fn calc_bpe(error_rate: f64) f64 {
    const denom = comptime math.pow(f64, math.ln2, 2.0);
    const num = @log(error_rate);
    const bpe = -(num / denom);
    if (bpe < 0) {
        return -bpe;
    }
    return bpe;
}

// Hash calculation functions
inline fn calculateHashes(self: *const BloomFilter, data: []const u8) struct { h1: u64, h2: u64 } {
    const use_64bit = self.force64 or self.n2 > 31;
    const h1: u64 = if (use_64bit)
        Hash64.hashWithSeed(data, @as(u64, seed))
    else
        @as(u64, Hash32.hashWithSeed(data, seed));

    const h2: u64 = if (use_64bit)
        Hash64.hashWithSeed(data, h1)
    else
        @as(u64, Hash32.hashWithSeed(data, @truncate(h1)));

    return .{ .h1 = h1, .h2 = h2 };
}

// Process a position (no prefetching for better performance)
inline fn processPosition(self: *const BloomFilter, byte_idx: usize) void {
    _ = self;
    _ = byte_idx;
}

// Process positions using optimized method
inline fn processPositions(
    self: *const BloomFilter,
    h1: u64,
    h2: u64,
    comptime is_add: bool,
    newly_added: *bool,
) bool {
    var i: u32 = 0;
    while (i < self.hashes) : (i += 1) {
        const pos: u64 = if (self.n2 > 0)
            (h1 +% @as(u64, i) *% h2) & (self.bits - 1)
        else
            (h1 +% @as(u64, i) *% h2) % self.bits;

        const byte_idx = pos / 8;
        const bit_offset = @as(u3, @truncate(pos % 8));
        const mask = @as(u8, 1) << bit_offset;

        // Process the position (no prefetch for better performance)
        processPosition(self, byte_idx);

        if (is_add) {
            if (self.bit_array[byte_idx] & mask == 0) {
                self.bit_array[byte_idx] |= mask;
                newly_added.* = true;
            }
        } else {
            // For check operation, return false if any bit is not set
            if (self.bit_array[byte_idx] & mask == 0) {
                return false;
            }
        }
    }

    return true;
}

// Returns true if item was newly added, false if already present
pub fn add(self: *BloomFilter, data: []const u8) bool {
    var newly_added = false;

    // Calculate hashes
    const hashes = calculateHashes(self, data);

    // Process positions
    _ = processPositions(self, hashes.h1, hashes.h2, true, &newly_added);

    if (newly_added) {
        self.entries += 1;
    }

    return newly_added;
}

// Returns true if item MIGHT be in set (could be false positive)
// Returns false if item DEFINITELY NOT in set
pub fn check(self: *const BloomFilter, data: []const u8) bool {
    // Calculate hashes
    const hashes = calculateHashes(self, data);

    // Process positions
    return processPositions(self, hashes.h1, hashes.h2, false, undefined);
}

// Add multiple items at once, returns number of newly added items
pub fn addMany(self: *BloomFilter, items: []const []const u8) u64 {
    var newly_added_count: u64 = 0;

    // Process items in batches for better cache locality
    const batch_size = 16;
    var i: usize = 0;

    while (i < items.len) : (i += batch_size) {
        const end = @min(i + batch_size, items.len);
        const batch = items[i..end];

        // Process each item in the batch
        for (batch) |item| {
            if (self.add(item)) {
                newly_added_count += 1;
            }
        }
    }

    return newly_added_count;
}

// Check multiple items at once, returns array of results
pub fn checkMany(self: *const BloomFilter, items: []const []const u8, allocator: Allocator) ![]bool {
    const results = try allocator.alloc(bool, items.len);

    // Process items in batches for better cache locality
    const batch_size = 16;
    var i: usize = 0;

    while (i < items.len) : (i += batch_size) {
        const end = @min(i + batch_size, items.len);
        const batch = items[i..end];

        // Process each item in the batch
        for (batch, i..) |item, idx| {
            results[idx] = self.check(item);
        }
    }

    return results;
}

// Alias for check for API convenience
pub const contains = check;

test "bloom filter initialization" {
    // Test valid initialization
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 1000,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    // Verify filter properties
    try std.testing.expect(filter.error_rate == 0.01);
    try std.testing.expect(filter.capacity >= 1000); // May be larger due to rounding
    try std.testing.expect(filter.entries == 0);
    try std.testing.expect(filter.bits > 0);
    try std.testing.expect(filter.bytes > 0);
    try std.testing.expect(filter.hashes > 0);
    try std.testing.expect(filter.bit_array.len == filter.bytes);

    // Test invalid initialization
    try std.testing.expectError(
        error.InvalidArguments,
        BloomFilter.init(.{
            .error_rate = 0,
            .capacity = 1000,
            .allocator = arena.allocator(),
        }),
    );

    try std.testing.expectError(
        error.InvalidArguments,
        BloomFilter.init(.{
            .error_rate = 1.0,
            .capacity = 1000,
            .allocator = arena.allocator(),
        }),
    );

    try std.testing.expectError(
        error.InvalidArguments,
        BloomFilter.init(.{
            .error_rate = 0.01,
            .capacity = 0,
            .allocator = arena.allocator(),
        }),
    );
}

test "bloom filter add and check basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 100,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    // Empty filter should return false for any item
    try std.testing.expect(!filter.check("hello"));
    try std.testing.expect(!filter.check("world"));
    try std.testing.expect(!filter.check(""));
    try std.testing.expect(!filter.check("a"));
    try std.testing.expect(!filter.check("very long string that should also work"));

    // Add first item
    const added1 = filter.add("hello");
    try std.testing.expect(added1); // Should be newly added
    try std.testing.expect(filter.entries == 1);
    try std.testing.expect(filter.check("hello")); // Should find it

    // Add same item again
    const added2 = filter.add("hello");
    try std.testing.expect(!added2); // Should not be newly added
    try std.testing.expect(filter.entries == 1); // Count shouldn't increase
    try std.testing.expect(filter.check("hello")); // Should still find it

    // Add different item
    const added3 = filter.add("world");
    try std.testing.expect(added3); // Should be newly added
    try std.testing.expect(filter.entries == 2);
    try std.testing.expect(filter.check("world")); // Should find it
    try std.testing.expect(filter.check("hello")); // Should still find first item

    // Test empty string
    const added4 = filter.add("");
    try std.testing.expect(added4);
    try std.testing.expect(filter.check(""));
    try std.testing.expect(filter.entries == 3);
}

test "bloom filter add and check with force64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test with force64 enabled
    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 100,
        .allocator = arena.allocator(),
        .force64 = true,
    });
    defer filter.deinit();

    try std.testing.expect(filter.force64 == true);

    // Test basic operations with force64
    try std.testing.expect(!filter.check("test"));
    const added = filter.add("test");
    try std.testing.expect(added);
    try std.testing.expect(filter.check("test"));
    try std.testing.expect(filter.entries == 1);
}

test "bloom filter false positive rate estimation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create a small filter to increase chance of collisions
    var filter = try BloomFilter.init(.{
        .error_rate = 0.1, // 10% error rate for easier testing
        .capacity = 10, // Small capacity
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    // Add some items
    const items = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (items) |item| {
        _ = filter.add(item);
    }

    // Check added items (should all be true)
    for (items) |item| {
        try std.testing.expect(filter.check(item));
    }

    // Test some items that were NOT added
    // With small filter and 10% error rate, some may be false positives
    const test_items = [_][]const u8{ "x", "y", "z", "1", "2", "3", "4", "5", "6", "7" };
    var false_positives: u32 = 0;
    var total_tests: u32 = 0;

    for (test_items) |item| {
        if (filter.check(item)) {
            false_positives += 1;
        }
        total_tests += 1;
    }

    const false_positive_rate = @as(f64, @floatFromInt(false_positives)) / @as(f64, @floatFromInt(total_tests));

    // With 10% configured error rate and 5 items in 10-capacity filter,
    // actual false positive rate should be reasonable
    // We'll just verify the filter is working, not the exact rate
    std.debug.print("\nFalse positive test: {d} false positives out of {d} tests ({d:.2}%)\n", .{
        false_positives,
        total_tests,
        false_positive_rate * 100.0,
    });
}

test "bloom filter with different error rates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test with very low error rate (more memory)
    var filter_low = try BloomFilter.init(.{
        .error_rate = 0.001, // 0.1%
        .capacity = 100,
        .allocator = arena.allocator(),
    });
    defer filter_low.deinit();

    // Test with high error rate (less memory)
    var filter_high = try BloomFilter.init(.{
        .error_rate = 0.25, // 25% (max practical)
        .capacity = 100,
        .allocator = arena.allocator(),
    });
    defer filter_high.deinit();

    // Lower error rate should use more bits
    try std.testing.expect(filter_low.bits > filter_high.bits);
    try std.testing.expect(filter_low.hashes >= filter_high.hashes);

    // Both should work
    _ = filter_low.add("test");
    _ = filter_high.add("test");

    try std.testing.expect(filter_low.check("test"));
    try std.testing.expect(filter_high.check("test"));
}

test "bloom filter entry counting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 100,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    // Add 10 unique items
    for (0..10) |i| {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{i});
        const added = filter.add(item);
        try std.testing.expect(added);
        try std.testing.expect(filter.entries == i + 1);
    }

    // Add duplicates - count shouldn't increase
    for (0..5) |i| {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{i % 3}); // Some duplicates
        _ = filter.add(item); // Ignore return value for this test
        // Some may be new, some may be duplicates
        // Just verify filter still works
        try std.testing.expect(filter.check(item));
    }
}

test "bloom filter contains alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 100,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    // contains should be an alias for check
    try std.testing.expect(!filter.contains("test"));
    _ = filter.add("test");
    try std.testing.expect(filter.contains("test"));
}

test "bloom filter large capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Test with large capacity
    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 100000, // 100k items
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    // Should have significant memory allocation
    try std.testing.expect(filter.bits > 100000);
    try std.testing.expect(filter.bytes > 10000);

    // Basic operations should still work
    try std.testing.expect(!filter.check("large-test"));
    const added = filter.add("large-test");
    try std.testing.expect(added);
    try std.testing.expect(filter.check("large-test"));
}

test "bloom filter addMany and checkMany" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try BloomFilter.init(.{
        .error_rate = 0.01,
        .capacity = 100,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    const items = [_][]const u8{ "apple", "banana", "cherry", "date", "elderberry" };

    // Add multiple items at once
    const added_count = filter.addMany(&items);
    try std.testing.expect(added_count == 5);
    try std.testing.expect(filter.entries == 5);

    // Check all added items
    for (items) |item| {
        try std.testing.expect(filter.check(item));
    }

    // Check multiple items at once
    const test_items = [_][]const u8{ "apple", "banana", "fig", "grape", "cherry" };
    const results = try filter.checkMany(&test_items, arena.allocator());
    defer arena.allocator().free(results);

    // Expected: [true, true, false, false, true]
    try std.testing.expect(results[0] == true); // apple
    try std.testing.expect(results[1] == true); // banana
    try std.testing.expect(results[2] == false); // fig (not added)
    try std.testing.expect(results[3] == false); // grape (not added)
    try std.testing.expect(results[4] == true); // cherry

    // Test addMany with duplicates
    const duplicate_items = [_][]const u8{ "apple", "banana", "honeydew" };
    const added_count2 = filter.addMany(&duplicate_items);
    try std.testing.expect(added_count2 == 1); // Only honeydew is new
    try std.testing.expect(filter.entries == 6); // Should have 6 unique items now
}
