const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ZedisSet = struct {
    allocator: Allocator,
    members: std.StringHashMapUnmanaged(void),

    pub fn init(allocator: Allocator) !*ZedisSet {
        const self = try allocator.create(ZedisSet);
        self.* = .{ .allocator = allocator, .members = .{} };
        return self;
    }

    pub fn deinit(self: *ZedisSet) void {
        var it = self.members.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.members.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Returns true if the member is new.
    pub fn add(self: *ZedisSet, member: []const u8) !bool {
        if (self.members.contains(member)) return false;
        const owned = try self.allocator.dupe(u8, member);
        errdefer self.allocator.free(owned);
        try self.members.putNoClobber(self.allocator, owned, {});
        return true;
    }

    /// Returns true if the member existed.
    pub fn remove(self: *ZedisSet, member: []const u8) bool {
        const kv = self.members.fetchRemove(member) orelse return false;
        self.allocator.free(kv.key);
        return true;
    }

    pub fn contains(self: *const ZedisSet, member: []const u8) bool {
        return self.members.contains(member);
    }

    pub fn len(self: *const ZedisSet) usize {
        return self.members.count();
    }

    pub fn iterator(self: *const ZedisSet) std.StringHashMapUnmanaged(void).KeyIterator {
        return self.members.keyIterator();
    }
};

const testing = std.testing;

test "add reports new members and remove releases them" {
    const s = try ZedisSet.init(testing.allocator);
    defer s.deinit();

    try testing.expect(try s.add("a"));
    try testing.expect(!try s.add("a"));
    try testing.expect(s.contains("a"));
    try testing.expect(s.remove("a"));
    try testing.expect(!s.remove("a"));
    try testing.expectEqual(@as(usize, 0), s.len());
}
