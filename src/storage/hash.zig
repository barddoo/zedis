const std = @import("std");
const Allocator = std.mem.Allocator;
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;

pub const ZedisHash = struct {
    allocator: Allocator,
    map: std.StringHashMapUnmanaged(PrimitiveValue),

    pub fn init(allocator: Allocator) !*ZedisHash {
        const self = try allocator.create(ZedisHash);
        self.* = .{
            .allocator = allocator,
            .map = .{},
        };
        return self;
    }

    pub fn deinit(self: *ZedisHash) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Sets field to value. Returns true if the field is new, false if it was updated.
    pub fn hset(self: *ZedisHash, field: []const u8, value: PrimitiveValue) !bool {
        const result = try self.map.getOrPut(self.allocator, field);
        if (result.found_existing) {
            result.value_ptr.deinit(self.allocator);
            result.value_ptr.* = value;
            return false;
        }
        result.key_ptr.* = try self.allocator.dupe(u8, field);
        result.value_ptr.* = value;
        return true;
    }

    pub fn hget(self: *const ZedisHash, field: []const u8) ?PrimitiveValue {
        return self.map.get(field);
    }

    /// Deletes a field. Returns true if the field existed.
    pub fn hdel(self: *ZedisHash, field: []const u8) bool {
        const kv = self.map.fetchRemove(field) orelse return false;
        self.allocator.free(kv.key);
        kv.value.deinit(self.allocator);
        return true;
    }

    pub fn hexists(self: *const ZedisHash, field: []const u8) bool {
        return self.map.contains(field);
    }

    pub fn hlen(self: *const ZedisHash) usize {
        return self.map.count();
    }

    pub fn iterator(self: *const ZedisHash) std.StringHashMapUnmanaged(PrimitiveValue).Iterator {
        return self.map.iterator();
    }
};
