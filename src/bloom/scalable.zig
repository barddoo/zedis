const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const BloomFilter = @import("./bloom_filter.zig").BloomFilter;

pub const ScalableBloomFilter = @This();

const Error = error{
    InvalidArguments,
    OutOfMemory,
    FilterFull,
};

allocator: Allocator,
links: ArrayList(Link),
total_entries: u64,
growth_factor: f64,
error_tightening_ratio: f64,
no_scaling: bool,

const Link = struct {
    filter: BloomFilter,
    entries: u64,
};

const ScalableBloomOptions = struct {
    initial_capacity: u64,
    error_rate: f64,
    allocator: Allocator,
    growth_factor: f64 = 2.0,
    error_tightening_ratio: f64 = 0.5,
    force64: bool = false,
    no_scaling: bool = false,
};

pub fn init(options: ScalableBloomOptions) !ScalableBloomFilter {
    if (options.initial_capacity < 1 or options.error_rate <= 0 or options.error_rate >= 1.0) {
        return error.InvalidArguments;
    }
    if (options.growth_factor <= 1.0) {
        return error.InvalidArguments;
    }
    if (options.error_tightening_ratio <= 0 or options.error_tightening_ratio >= 1.0) {
        return error.InvalidArguments;
    }

    var links = ArrayList(Link){};
    try links.ensureTotalCapacity(options.allocator, 1);
    errdefer links.deinit(options.allocator);

    const first_filter = try BloomFilter.init(.{
        .error_rate = options.error_rate,
        .capacity = options.initial_capacity,
        .allocator = options.allocator,
        .force64 = options.force64,
    });

    links.appendAssumeCapacity(.{
        .filter = first_filter,
        .entries = 0,
    });

    return ScalableBloomFilter{
        .allocator = options.allocator,
        .links = links,
        .total_entries = 0,
        .growth_factor = options.growth_factor,
        .error_tightening_ratio = options.error_tightening_ratio,
        .no_scaling = options.no_scaling,
    };
}

pub fn deinit(self: *ScalableBloomFilter) void {
    for (self.links.items) |*link| {
        link.filter.deinit();
    }
    self.links.deinit(self.allocator);
}

fn getCurrentLink(self: *ScalableBloomFilter) *Link {
    return &self.links.items[self.links.items.len - 1];
}

fn getCurrentLinkConst(self: *const ScalableBloomFilter) *const Link {
    return &self.links.items[self.links.items.len - 1];
}

fn expand(self: *ScalableBloomFilter) !void {
    const current = self.getCurrentLink();

    const new_capacity = @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(current.filter.capacity)) * self.growth_factor)));
    const new_error_rate = current.filter.error_rate * self.error_tightening_ratio;

    const new_filter = try BloomFilter.init(.{
        .error_rate = new_error_rate,
        .capacity = new_capacity,
        .allocator = self.allocator,
        .force64 = current.filter.force64,
    });

    try self.links.append(self.allocator, .{
        .filter = new_filter,
        .entries = 0,
    });
}

pub fn check(self: *const ScalableBloomFilter, data: []const u8) bool {
    var i = self.links.items.len;
    while (i > 0) {
        i -= 1;
        const link = &self.links.items[i];
        if (link.filter.check(data)) {
            return true;
        }
    }
    return false;
}

pub fn add(self: *ScalableBloomFilter, data: []const u8) !bool {
    if (self.check(data)) {
        return false;
    }

    var current = self.getCurrentLink();

    if (current.entries >= current.filter.capacity) {
        if (self.no_scaling) {
            return error.FilterFull;
        }
        try self.expand();
        current = self.getCurrentLink();
    }

    const added = current.filter.add(data);
    if (added) {
        current.entries += 1;
        self.total_entries += 1;
    }

    return added;
}

pub fn contains(self: *const ScalableBloomFilter, data: []const u8) bool {
    return self.check(data);
}

pub fn getFilterCount(self: *const ScalableBloomFilter) usize {
    return self.links.items.len;
}

pub fn getTotalEntries(self: *const ScalableBloomFilter) u64 {
    return self.total_entries;
}

pub fn getMemoryUsage(self: *const ScalableBloomFilter) u64 {
    var total: u64 = 0;
    for (self.links.items) |link| {
        total += link.filter.bytes;
    }
    return total;
}

test "scalable bloom filter initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 100,
        .error_rate = 0.01,
        .allocator = arena.allocator(),
        .growth_factor = 2.0,
        .error_tightening_ratio = 0.5,
    });
    defer filter.deinit();

    try std.testing.expect(filter.getFilterCount() == 1);
    try std.testing.expect(filter.getTotalEntries() == 0);
    try std.testing.expect(!filter.no_scaling);
}

test "scalable bloom filter basic add and check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 10,
        .error_rate = 0.1,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    try std.testing.expect(!filter.check("hello"));

    const added = try filter.add("hello");
    try std.testing.expect(added);
    try std.testing.expect(filter.getTotalEntries() == 1);
    try std.testing.expect(filter.check("hello"));

    const added_again = try filter.add("hello");
    try std.testing.expect(!added_again);
    try std.testing.expect(filter.getTotalEntries() == 1);
}

test "scalable bloom filter multiple items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 5,
        .error_rate = 0.1,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    const items = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (items) |item| {
        const added = try filter.add(item);
        try std.testing.expect(added);
    }

    try std.testing.expect(filter.getTotalEntries() == 5);

    for (items) |item| {
        try std.testing.expect(filter.check(item));
    }

    try std.testing.expect(!filter.check("not-added"));
}

test "scalable bloom filter expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 10,
        .error_rate = 0.01,
        .allocator = arena.allocator(),
        .growth_factor = 2.0,
        .error_tightening_ratio = 0.5,
    });
    defer filter.deinit();

    try std.testing.expect(filter.getFilterCount() == 1);

    // Check the actual capacity of the first filter
    const first_filter = &filter.links.items[0].filter;
    const actual_capacity = first_filter.capacity;

    // Add items until we fill the first filter
    var i: u64 = 0;
    while (i < actual_capacity) : (i += 1) {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{i});
        _ = try filter.add(item);
    }

    try std.testing.expect(filter.getFilterCount() == 1);
    try std.testing.expect(filter.getTotalEntries() == actual_capacity);

    // Adding one more item should trigger expansion
    _ = try filter.add("extra-item");

    try std.testing.expect(filter.getFilterCount() == 2);
    try std.testing.expect(filter.getTotalEntries() == actual_capacity + 1);
}

test "scalable bloom filter no scaling mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 10,
        .error_rate = 0.01,
        .allocator = arena.allocator(),
        .no_scaling = true,
    });
    defer filter.deinit();

    // Check the actual capacity
    const first_filter = &filter.links.items[0].filter;
    const actual_capacity = first_filter.capacity;

    // Fill the filter to capacity
    var i: u64 = 0;
    while (i < actual_capacity) : (i += 1) {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{i});
        _ = try filter.add(item);
    }

    // Next add should fail with FilterFull
    try std.testing.expectError(
        error.FilterFull,
        filter.add("extra-item"),
    );

    try std.testing.expect(filter.getFilterCount() == 1);
    try std.testing.expect(filter.getTotalEntries() == actual_capacity);
}

test "scalable bloom filter check reverse order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 10,
        .error_rate = 0.01,
        .allocator = arena.allocator(),
        .growth_factor = 2.0,
    });
    defer filter.deinit();

    // Check the actual capacity
    const first_filter = &filter.links.items[0].filter;
    const actual_capacity = first_filter.capacity;

    // Fill the first filter
    var i: u64 = 0;
    while (i < actual_capacity) : (i += 1) {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{i});
        _ = try filter.add(item);
    }

    // Add one more to trigger expansion
    _ = try filter.add("extra-item");

    // All items should be found
    for (0..actual_capacity) |j| {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{j});
        try std.testing.expect(filter.check(item));
    }
    try std.testing.expect(filter.check("extra-item"));

    try std.testing.expect(filter.getFilterCount() == 2);
}

test "scalable bloom filter memory usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 10,
        .error_rate = 0.01,
        .allocator = arena.allocator(),
    });
    defer filter.deinit();

    const initial_memory = filter.getMemoryUsage();
    try std.testing.expect(initial_memory > 0);

    for (0..15) |i| {
        var buf: [20]u8 = undefined;
        const item = try std.fmt.bufPrint(&buf, "item-{}", .{i});
        _ = try filter.add(item);
    }

    const final_memory = filter.getMemoryUsage();
    try std.testing.expect(final_memory > initial_memory);
}

test "scalable bloom filter with force64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var filter = try ScalableBloomFilter.init(.{
        .initial_capacity = 10,
        .error_rate = 0.01,
        .allocator = arena.allocator(),
        .force64 = true,
    });
    defer filter.deinit();

    _ = try filter.add("test64");
    try std.testing.expect(filter.check("test64"));

    const first_filter = &filter.links.items[0].filter;
    try std.testing.expect(first_filter.force64 == true);
}

test "scalable bloom filter invalid initialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidArguments,
        ScalableBloomFilter.init(.{
            .initial_capacity = 0,
            .error_rate = 0.01,
            .allocator = arena.allocator(),
        }),
    );

    try std.testing.expectError(
        error.InvalidArguments,
        ScalableBloomFilter.init(.{
            .initial_capacity = 10,
            .error_rate = 0,
            .allocator = arena.allocator(),
        }),
    );

    try std.testing.expectError(
        error.InvalidArguments,
        ScalableBloomFilter.init(.{
            .initial_capacity = 10,
            .error_rate = 1.0,
            .allocator = arena.allocator(),
        }),
    );

    try std.testing.expectError(
        error.InvalidArguments,
        ScalableBloomFilter.init(.{
            .initial_capacity = 10,
            .error_rate = 0.01,
            .allocator = arena.allocator(),
            .growth_factor = 0.5,
        }),
    );

    try std.testing.expectError(
        error.InvalidArguments,
        ScalableBloomFilter.init(.{
            .initial_capacity = 10,
            .error_rate = 0.01,
            .allocator = arena.allocator(),
            .error_tightening_ratio = 0,
        }),
    );
}
