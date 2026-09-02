const std = @import("std");

pub const Allocator = std.mem.Allocator;

const TagSet = std.AutoHashMapUnmanaged(u64, void);
const separator: u8 = ',';

/// Per-field tag index. Tag values are exact-match, case-insensitive.
/// Values are comma-separated (RediSearch default SEPARATOR).
pub const TagIndex = struct {
    allocator: Allocator,
    map: std.StringHashMapUnmanaged(TagSet) = .empty,

    pub fn init(allocator: Allocator) TagIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TagIndex) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
    }

    pub fn add(self: *TagIndex, doc_id: u64, value: []const u8) !void {
        var tags: std.ArrayListUnmanaged([]const u8) = .empty;
        defer tags.deinit(self.allocator);
        try splitTags(self.allocator, value, &tags);

        for (tags.items) |tag| {
            const gop = try self.map.getOrPut(self.allocator, tag);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, tag);
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.put(self.allocator, doc_id, {});
        }
    }

    pub fn remove(self: *TagIndex, doc_id: u64, value: []const u8) void {
        var tags: std.ArrayListUnmanaged([]const u8) = .empty;
        defer tags.deinit(self.allocator);
        splitTags(self.allocator, value, &tags) catch return;

        for (tags.items) |tag| {
            if (self.map.getPtr(tag)) |set| {
                _ = set.remove(doc_id);
                if (set.count() == 0) {
                    if (self.map.fetchRemove(tag)) |kv| {
                        self.allocator.free(kv.key);
                        var tag_value = kv.value;
                        tag_value.deinit(self.allocator);
                    }
                }
            }
        }
    }

    /// Doc ids for an exact tag (case-insensitive). Null if tag absent.
    pub fn docIds(self: *const TagIndex, tag: []const u8) ?*const TagSet {
        return self.map.getPtr(tag);
    }

    pub fn tagCount(self: *const TagIndex) usize {
        return self.map.count();
    }
};

fn splitTags(allocator: Allocator, value: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var start: usize = 0;
    var i: usize = 0;
    while (i <= value.len) : (i += 1) {
        const is_sep = i == value.len or value[i] == separator;
        if (is_sep) {
            if (i > start) {
                try out.append(allocator, value[start..i]);
            }
            start = i + 1;
        }
    }
}

/// Lowercases a tag into a stack buffer for map lookups.
pub fn normalized(allocator: Allocator, tag: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, tag);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

const testing = std.testing;

test "tag add and lookup" {
    var ti = TagIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.add(1, "red,blue");
    try ti.add(2, "green");
    try ti.add(3, "red");

    try testing.expectEqual(@as(usize, 2), ti.docIds("red").?.count());
    try testing.expectEqual(@as(usize, 1), ti.docIds("blue").?.count());
    try testing.expect(ti.docIds("red").?.contains(1));
    try testing.expect(ti.docIds("red").?.contains(3));
}

test "tag remove" {
    var ti = TagIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.add(1, "red");
    try ti.add(2, "red");
    ti.remove(1, "red");

    try testing.expectEqual(@as(usize, 1), ti.docIds("red").?.count());
    try testing.expect(ti.docIds("red").?.contains(2));
    try testing.expect(!ti.docIds("red").?.contains(1));
}

test "tag empty after removing last doc" {
    var ti = TagIndex.init(testing.allocator);
    defer ti.deinit();

    try ti.add(1, "solo");
    ti.remove(1, "solo");
    try testing.expect(ti.docIds("solo") == null);
    try testing.expectEqual(@as(usize, 0), ti.tagCount());
}
