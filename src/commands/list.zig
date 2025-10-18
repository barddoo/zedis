const std = @import("std");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const PrimitiveValue = @import("../store.zig").PrimitiveValue;
const ZedisListNode = @import("../list.zig").ZedisListNode;
const ZedisList = @import("../list.zig").ZedisList;
const Store = @import("../store.zig").Store;
const resp = @import("./resp.zig");

/// Helper function to normalize a list index (handles negative indices).
/// Returns null if the index is out of bounds.
inline fn normalizeListIndex(index: i64, list_len: usize) ?usize {
    return ZedisList.normalizeIndex(index, list_len);
}

/// Helper function to normalize a range index with clamping behavior.
/// Used by LRANGE which clamps out-of-bounds indices instead of returning errors.
/// Returns null only when the start index is beyond the list length (should return empty list).
inline fn normalizeRangeIndex(index: i64, list_len: usize, comptime is_start: bool) ?usize {
    if (index < 0) {
        const neg_offset = @as(usize, @intCast(-index));
        if (neg_offset > list_len) {
            return 0; // Clamp to start
        }
        return list_len - neg_offset;
    } else {
        const pos_index = @as(usize, @intCast(index));
        if (is_start) {
            // For start index: if beyond list, signal empty range
            if (pos_index >= list_len) return null;
        } else {
            // For stop index: clamp to last element
            if (pos_index >= list_len) return list_len - 1;
        }
        return pos_index;
    }
}

pub fn lpush(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const list = try store.getSetList(key);

    for (args[2..]) |arg| {
        try list.prepend(.{ .string = arg.asSlice() });
    }

    try resp.writeInt(writer, list.len());
}

pub fn rpush(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();

    const list = try store.getSetList(key);

    for (args[2..]) |arg| {
        try list.append(.{ .string = arg.asSlice() });
    }

    try resp.writeInt(writer, list.len());
}

pub fn lpop(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const list = try store.getList(key) orelse {
        try resp.writeNull(writer);
        return;
    };

    var count: usize = 1;

    if (args.len == 3) {
        count = try args[2].asUsize();
    }

    const list_len = list.len();
    const actual_count = @min(count, list_len);

    if (actual_count == 0) {
        try resp.writeNull(writer);
        return;
    }

    if (actual_count == 1) {
        const item = list.popFirst().?;
        try resp.writePrimitiveValue(writer, item);
        return;
    }
    if (actual_count > 1) {
        try resp.writeListLen(writer, actual_count);
        for (0..actual_count) |_| {
            const item = list.popFirst().?;
            try resp.writePrimitiveValue(writer, item);
        }
        return;
    }
}

pub fn rpop(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const list = try store.getList(key) orelse {
        try resp.writeNull(writer);
        return;
    };

    var count: usize = 1;

    if (args.len == 3) {
        count = try args[2].asUsize();
    }

    const list_len = list.len();
    const actual_count = @min(count, list_len);

    if (actual_count == 0) {
        try resp.writeNull(writer);
        return;
    }

    if (actual_count == 1) {
        const item = list.pop().?;
        try resp.writePrimitiveValue(writer, item);
        return;
    }
    if (actual_count > 1) {
        try resp.writeListLen(writer, actual_count);
        for (0..actual_count) |_| {
            const item = list.pop().?;
            try resp.writePrimitiveValue(writer, item);
        }
        return;
    }
}

pub fn llen(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const list = try store.getList(key);

    if (list) |l| {
        try resp.writeInt(writer, l.len());
    } else {
        try resp.writeInt(writer, 0);
    }
}

pub fn lindex(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const index = try args[2].asInt();
    const list = try store.getList(key) orelse {
        try resp.writeNull(writer);
        return;
    };

    const actual_index = normalizeListIndex(index, list.len()) orelse {
        try resp.writeNull(writer);
        return;
    };

    const item = list.getByIndex(actual_index) orelse {
        try resp.writeNull(writer);
        return;
    };

    try resp.writePrimitiveValue(writer, item);
}

pub fn lset(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const index = try args[2].asInt();
    const value = args[3].asSlice();

    const list = try store.getList(key) orelse {
        return error.NoSuchKey;
    };

    const actual_index = normalizeListIndex(index, list.len()) orelse {
        return error.KeyNotFound;
    };

    try list.setByIndex(actual_index, .{ .string = value });

    try resp.writeOK(writer);
}

pub fn lrange(writer: *std.Io.Writer, store: *Store, args: []const Value) !void {
    const key = args[1].asSlice();
    const start = try args[2].asInt();
    const stop = try args[3].asInt();

    const list = try store.getList(key) orelse {
        try resp.writeListLen(writer, 0);
        return;
    };

    const list_len = list.len();
    if (list_len == 0) {
        try resp.writeListLen(writer, 0);
        return;
    }

    // Normalize indices with clamping behavior
    const actual_start = normalizeRangeIndex(start, list_len, true) orelse {
        try resp.writeListLen(writer, 0);
        return;
    };

    const actual_stop = normalizeRangeIndex(stop, list_len, false) orelse {
        try resp.writeListLen(writer, 0);
        return;
    };

    // Handle invalid range
    if (actual_start > actual_stop) {
        try resp.writeListLen(writer, 0);
        return;
    }

    const count = actual_stop - actual_start + 1;
    try resp.writeListLen(writer, count);

    // Stream items directly without intermediate allocation
    var current = list.list.first;
    var i: usize = 0;
    while (current) |node| : (i += 1) {
        if (i >= actual_start and i <= actual_stop) {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            try resp.writePrimitiveValue(writer, list_node.data);
        }
        if (i > actual_stop) break;
        current = node.next;
    }
}
