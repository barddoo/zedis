const std = @import("std");
const assert = std.debug.assert;

pub const ShortString = struct {
    data: [23]u8,
    len: u8,

    pub fn fromSlice(str: []const u8) ShortString {
        assert(str.len <= 23);
        var ss: ShortString = .{ .data = undefined, .len = @intCast(str.len) };
        @memcpy(ss.data[0..str.len], str);
        @memset(ss.data[str.len..], 0);
        return ss;
    }

    pub fn asSlice(self: *const ShortString) []const u8 {
        return self.data[0..self.len];
    }
};

pub const PrimitiveValue = union(enum) {
    string: []const u8,
    short_string: ShortString,
    int: i64,

    pub fn fromSlice(str: []const u8, allocator: std.mem.Allocator) !PrimitiveValue {
        if (str.len <= 23) {
            return .{ .short_string = ShortString.fromSlice(str) };
        }
        const duped = try allocator.dupe(u8, str);
        return .{ .string = duped };
    }
};

pub const invalid_client_slot_index: u32 = std.math.maxInt(u32);

pub const ClientHandle = struct {
    slot_index: u32,
    generation: u32,

    pub fn eql(a: ClientHandle, b: ClientHandle) bool {
        return a.slot_index == b.slot_index and a.generation == b.generation;
    }
};
