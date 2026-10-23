const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const NumEntry = struct {
    doc_id: u64,
    value: f64,
};

/// Per-field numeric index. V1 keeps a flat list and linear-scans for range
/// queries (exact, simple). Can be replaced with a sorted structure later.
pub const NumericIndex = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(NumEntry) = .empty,

    pub fn init(allocator: Allocator) NumericIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NumericIndex) void {
        self.entries.deinit(self.allocator);
    }

    pub fn add(self: *NumericIndex, doc_id: u64, value: f64) !void {
        try self.entries.append(self.allocator, .{ .doc_id = doc_id, .value = value });
    }

    pub fn remove(self: *NumericIndex, doc_id: u64) void {
        for (self.entries.items, 0..) |e, i| {
            if (e.doc_id == doc_id) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    /// Collects doc_ids with min <= value <= max into `out`.
    pub fn range(self: *const NumericIndex, min: ?f64, max: ?f64, out: *std.ArrayListUnmanaged(u64)) !void {
        for (self.entries.items) |e| {
            if (min) |mn| {
                if (e.value < mn) continue;
            }
            if (max) |mx| {
                if (e.value > mx) continue;
            }
            try out.append(self.allocator, e.doc_id);
        }
    }
};

const testing = std.testing;

test "numeric range filtering" {
    var ni = NumericIndex.init(testing.allocator);
    defer ni.deinit();

    try ni.add(1, 4.5);
    try ni.add(2, 10.0);
    try ni.add(3, 25.0);
    try ni.add(4, 80.0);

    var out: std.ArrayListUnmanaged(u64) = .empty;
    defer out.deinit(testing.allocator);
    try ni.range(10.0, 50.0, &out);

    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(out.items[0] == 2 or out.items[1] == 2);
    try testing.expect(out.items[0] == 3 or out.items[1] == 3);
}

test "numeric remove" {
    var ni = NumericIndex.init(testing.allocator);
    defer ni.deinit();

    try ni.add(1, 1.0);
    try ni.add(2, 2.0);
    ni.remove(1);

    var out: std.ArrayListUnmanaged(u64) = .empty;
    defer out.deinit(testing.allocator);
    try ni.range(null, null, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u64, 2), out.items[0]);
}
