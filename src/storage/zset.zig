const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sorted set: a member->score map for O(1) lookup plus an array kept ordered by
/// (score, member) for rank and range queries. Inserts are O(n) memmoves, which
/// is fine for the scheduled/retry sets this targets; swap `order` for a skiplist
/// if very large zsets with random inserts matter.
pub const ZedisZSet = struct {
    pub const Entry = struct {
        score: f64,
        /// Points at the key owned by `scores`; stable until the member is removed.
        member: []const u8,
    };

    pub const AddResult = enum { added, updated, unchanged };

    allocator: Allocator,
    scores: std.StringHashMapUnmanaged(f64),
    order: std.ArrayList(Entry),

    pub fn init(allocator: Allocator) !*ZedisZSet {
        const self = try allocator.create(ZedisZSet);
        self.* = .{ .allocator = allocator, .scores = .{}, .order = .empty };
        return self;
    }

    pub fn deinit(self: *ZedisZSet) void {
        var it = self.scores.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.scores.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn len(self: *const ZedisZSet) usize {
        return self.order.items.len;
    }

    pub fn score(self: *const ZedisZSet, member: []const u8) ?f64 {
        return self.scores.get(member);
    }

    fn precedes(entry: Entry, s: f64, member: []const u8) bool {
        if (entry.score != s) return entry.score < s;
        return std.mem.order(u8, entry.member, member) == .lt;
    }

    /// Branchless binary search: each step is a conditional select on a fixed
    /// halving schedule, so no data-dependent branch to mispredict.
    fn lower_bound(self: *const ZedisZSet, s: f64, member: []const u8) usize {
        const items = self.order.items;
        var base: usize = 0;
        var size = items.len;
        while (size > 1) {
            const half = size / 2;
            base = if (precedes(items[base + half - 1], s, member)) base + half else base;
            size -= half;
        }
        return base + @intFromBool(size == 1 and precedes(items[base], s, member));
    }

    /// Never fails after the pop point: capacity is reserved first so an OOM
    /// cannot leave the map and the ordered array disagreeing.
    pub fn add(self: *ZedisZSet, member: []const u8, new_score: f64) !AddResult {
        try self.order.ensureUnusedCapacity(self.allocator, 1);

        if (self.scores.getPtr(member)) |old| {
            if (old.* == new_score) return .unchanged;
            const idx = self.lower_bound(old.*, member);
            const key = self.order.items[idx].member;
            _ = self.order.orderedRemove(idx);
            old.* = new_score;
            self.order.insertAssumeCapacity(self.lower_bound(new_score, key), .{ .score = new_score, .member = key });
            return .updated;
        }

        const owned = try self.allocator.dupe(u8, member);
        errdefer self.allocator.free(owned);
        try self.scores.putNoClobber(self.allocator, owned, new_score);
        self.order.insertAssumeCapacity(self.lower_bound(new_score, owned), .{ .score = new_score, .member = owned });
        return .added;
    }

    /// Returns true if the member existed.
    pub fn remove(self: *ZedisZSet, member: []const u8) bool {
        const kv = self.scores.fetchRemove(member) orelse return false;
        _ = self.order.orderedRemove(self.lower_bound(kv.value, member));
        self.allocator.free(kv.key);
        return true;
    }

    /// Removes every entry in [start, end) and returns how many were removed.
    pub fn remove_range(self: *ZedisZSet, start: usize, end: usize) usize {
        for (self.order.items[start..end]) |entry| {
            const kv = self.scores.fetchRemove(entry.member).?;
            self.allocator.free(kv.key);
        }
        const count = end - start;
        self.order.replaceRangeAssumeCapacity(start, count, &.{});
        return count;
    }

    /// Index of the first entry at or above `min` (above, when exclusive).
    pub fn first_index_from(self: *const ZedisZSet, min: f64, exclusive: bool) usize {
        const items = self.order.items;
        var base: usize = 0;
        var size = items.len;
        while (size > 1) {
            const half = size / 2;
            const s = items[base + half - 1].score;
            base = if (if (exclusive) s <= min else s < min) base + half else base;
            size -= half;
        }
        const last_below = size == 1 and (if (exclusive) items[base].score <= min else items[base].score < min);
        return base + @intFromBool(last_below);
    }

    /// Index one past the last entry at or below `max` (below, when exclusive).
    pub fn end_index_to(self: *const ZedisZSet, max: f64, exclusive: bool) usize {
        const items = self.order.items;
        var base: usize = 0;
        var size = items.len;
        while (size > 1) {
            const half = size / 2;
            const s = items[base + half - 1].score;
            base = if (if (exclusive) s < max else s <= max) base + half else base;
            size -= half;
        }
        const last_within = size == 1 and (if (exclusive) items[base].score < max else items[base].score <= max);
        return base + @intFromBool(last_within);
    }
};

const testing = std.testing;

test "entries stay ordered by score then member and updates reposition them" {
    const z = try ZedisZSet.init(testing.allocator);
    defer z.deinit();

    try testing.expectEqual(.added, try z.add("b", 2));
    try testing.expectEqual(.added, try z.add("a", 2));
    try testing.expectEqual(.added, try z.add("c", 1));
    try testing.expectEqual(.unchanged, try z.add("c", 1));
    try testing.expectEqual(.updated, try z.add("c", 3));

    const expected = [_][]const u8{ "a", "b", "c" };
    for (expected, z.order.items) |name, entry| try testing.expectEqualStrings(name, entry.member);
    try testing.expectEqual(@as(?f64, 3), z.score("c"));
}

test "score range bounds honor exclusivity" {
    const z = try ZedisZSet.init(testing.allocator);
    defer z.deinit();
    for ([_]f64{ 1, 2, 2, 3 }, [_][]const u8{ "a", "b", "c", "d" }) |s, m| _ = try z.add(m, s);

    try testing.expectEqual(@as(usize, 1), z.first_index_from(2, false));
    try testing.expectEqual(@as(usize, 3), z.first_index_from(2, true));
    try testing.expectEqual(@as(usize, 3), z.end_index_to(2, false));
    try testing.expectEqual(@as(usize, 1), z.end_index_to(2, true));
}

test "remove and remove_range release members" {
    const z = try ZedisZSet.init(testing.allocator);
    defer z.deinit();
    for ([_]f64{ 1, 2, 3, 4 }, [_][]const u8{ "a", "b", "c", "d" }) |s, m| _ = try z.add(m, s);

    try testing.expect(z.remove("a"));
    try testing.expect(!z.remove("a"));
    try testing.expectEqual(@as(usize, 2), z.remove_range(0, 2));
    try testing.expectEqual(@as(usize, 1), z.len());
    try testing.expectEqual(@as(?f64, null), z.score("b"));
}
