const std = @import("std");
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;

pub const ZedisListNode = struct {
    data: PrimitiveValue,
    node: std.DoublyLinkedList.Node = .{},
};

pub const ZedisList = struct {
    list: std.DoublyLinkedList = .{},
    allocator: std.mem.Allocator,
    cached_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ZedisList {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ZedisList) void {
        var current = self.list.first;
        while (current) |node| {
            current = node.next;
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            switch (list_node.data) {
                .string => |str| self.allocator.free(str),
                .int, .short_string => {},
            }
            self.allocator.destroy(list_node);
        }
        self.list = .{};
    }

    pub inline fn len(self: *const ZedisList) usize {
        return self.cached_len;
    }

    pub fn prepend(self: *ZedisList, value: PrimitiveValue) !void {
        const list_node = try self.allocator.create(ZedisListNode);
        list_node.* = ZedisListNode{ .data = value };
        self.list.prepend(&list_node.node);
        self.cached_len += 1;
    }

    pub fn append(self: *ZedisList, value: PrimitiveValue) !void {
        const list_node = try self.allocator.create(ZedisListNode);
        list_node.* = ZedisListNode{ .data = value };
        self.list.append(&list_node.node);
        self.cached_len += 1;
    }

    /// Splices an already-allocated node into the list. Used by LPUSH/RPUSH to
    /// stage every element before touching the list, so a failed push leaves
    /// the key untouched.
    pub fn prepend_node(self: *ZedisList, node: *std.DoublyLinkedList.Node) void {
        self.list.prepend(node);
        self.cached_len += 1;
    }

    pub fn append_node(self: *ZedisList, node: *std.DoublyLinkedList.Node) void {
        self.list.append(node);
        self.cached_len += 1;
    }

    /// Detaches the head node without freeing it, so LMOVE can relink it into
    /// another list with no allocation that could fail after the pop.
    pub fn pop_first_node(self: *ZedisList) ?*std.DoublyLinkedList.Node {
        const node = self.list.popFirst() orelse return null;
        self.cached_len -= 1;
        return node;
    }

    pub fn pop_node(self: *ZedisList) ?*std.DoublyLinkedList.Node {
        const node = self.list.popLast() orelse return null;
        self.cached_len -= 1;
        return node;
    }

    pub fn pop_first(self: *ZedisList) ?PrimitiveValue {
        const node = self.list.popFirst() orelse return null;
        const list_node: *ZedisListNode = @fieldParentPtr("node", node);
        const value = list_node.data;
        self.allocator.destroy(list_node);
        self.cached_len -= 1;
        return value;
    }

    pub fn pop(self: *ZedisList) ?PrimitiveValue {
        const node = self.list.popLast() orelse return null;
        const list_node: *ZedisListNode = @fieldParentPtr("node", node);
        const value = list_node.data;
        self.allocator.destroy(list_node);
        self.cached_len -= 1;
        return value;
    }

    /// Normalize a signed index to an unsigned index.
    /// Returns null if the index is out of bounds.
    /// Negative indices count from the end: -1 is the last element, -2 is second to last, etc.
    pub fn normalize_index(index: i64, list_len: usize) ?usize {
        if (list_len == 0) return null;

        if (index < 0) {
            const neg_offset = @as(usize, @intCast(-index));
            if (neg_offset > list_len) return null;
            return list_len - neg_offset;
        } else {
            const pos_index = @as(usize, @intCast(index));
            if (pos_index >= list_len) return null;
            return pos_index;
        }
    }

    /// Get the node at the specified index using bidirectional traversal.
    /// Optimizes by starting from the closest end (first or last).
    fn get_node_at(self: *const ZedisList, actual_index: usize) ?*ZedisListNode {
        const list_len = self.cached_len;

        // O(1) optimization for first index
        if (actual_index == 0) {
            const node = self.list.first orelse return null;
            return @fieldParentPtr("node", node);
        }

        // O(1) optimization for last index
        if (actual_index == list_len - 1) {
            const node = self.list.last orelse return null;
            return @fieldParentPtr("node", node);
        }

        // O(n/2) traversal: start from the closest end
        if (actual_index >= list_len / 2) {
            // Start from the end if the index is in the second half
            var current = self.list.last;
            var i: usize = list_len - 1;
            while (current) |node| {
                if (i == actual_index) {
                    return @fieldParentPtr("node", node);
                }
                current = node.prev;
                i -= 1;
            }
        } else {
            // Start from the beginning if the index is in the first half
            var current = self.list.first;
            var i: usize = 0;
            while (current) |node| {
                if (i == actual_index) {
                    return @fieldParentPtr("node", node);
                }
                current = node.next;
                i += 1;
            }
        }

        return null;
    }

    pub fn get_by_index(self: *const ZedisList, index: usize) ?PrimitiveValue {
        const list_node = self.get_node_at(index) orelse return null;
        return list_node.data;
    }

    pub fn set_by_index(self: *ZedisList, index: usize, value: PrimitiveValue) !void {
        const list_node = self.get_node_at(index) orelse return error.KeyNotFound;
        switch (list_node.data) {
            .string => |str| self.allocator.free(str),
            .int, .short_string => {},
        }
        list_node.data = value;
    }

    fn primitive_eql_slice(pv: PrimitiveValue, s: []const u8) bool {
        return switch (pv) {
            .string => |str| std.mem.eql(u8, str, s),
            .short_string => |ss| std.mem.eql(u8, ss.as_slice(), s),
            .int => |i| (std.fmt.parseInt(i64, s, 10) catch return false) == i,
        };
    }

    /// Remove up to `|count|` elements equal to `value`.
    /// count > 0: scan head→tail; count < 0: scan tail→head; count == 0: remove all.
    /// Returns number of elements removed.
    pub fn remove(self: *ZedisList, count: i64, value: []const u8) usize {
        const remove_all = count == 0;
        const limit: usize = if (remove_all) std.math.maxInt(usize) else @intCast(@abs(count));
        var removed: usize = 0;

        if (count >= 0) {
            var current = self.list.first;
            while (current) |node| {
                if (removed >= limit) break;
                current = node.next;
                const list_node: *ZedisListNode = @fieldParentPtr("node", node);
                if (primitive_eql_slice(list_node.data, value)) {
                    self.list.remove(node);
                    self.cached_len -= 1;
                    switch (list_node.data) {
                        .string => |str| self.allocator.free(str),
                        .int, .short_string => {},
                    }
                    self.allocator.destroy(list_node);
                    removed += 1;
                }
            }
        } else {
            var current = self.list.last;
            while (current) |node| {
                if (removed >= limit) break;
                current = node.prev;
                const list_node: *ZedisListNode = @fieldParentPtr("node", node);
                if (primitive_eql_slice(list_node.data, value)) {
                    self.list.remove(node);
                    self.cached_len -= 1;
                    switch (list_node.data) {
                        .string => |str| self.allocator.free(str),
                        .int, .short_string => {},
                    }
                    self.allocator.destroy(list_node);
                    removed += 1;
                }
            }
        }
        return removed;
    }

    /// Keep only elements in [start, stop] (inclusive, 0-based, negative indices from tail).
    /// Elements outside the range are removed.
    pub fn trim(self: *ZedisList, start_raw: i64, stop_raw: i64) void {
        const list_len = self.cached_len;
        if (list_len == 0) return;

        const start: usize = if (start_raw < 0) blk: {
            const offset = @as(usize, @intCast(-start_raw));
            break :blk if (offset > list_len) 0 else list_len - offset;
        } else @intCast(start_raw);

        const stop: usize = if (stop_raw < 0) blk: {
            const offset = @as(usize, @intCast(-stop_raw));
            break :blk if (offset > list_len) 0 else list_len - offset;
        } else @min(@as(usize, @intCast(stop_raw)), list_len - 1);

        if (start > stop or start >= list_len) {
            self.deinit();
            return;
        }

        // drop elements before start
        var i: usize = 0;
        while (i < start) : (i += 1) {
            _ = self.pop_first();
        }

        // cached_len updated by pop_first; now drop elements after stop - start
        const keep = stop - start + 1;
        while (self.cached_len > keep) {
            _ = self.pop();
        }
    }

    /// Insert `value` before or after the first occurrence of `pivot`.
    /// Returns the new list length, or null if pivot not found, or error on OOM.
    pub fn insert_before(self: *ZedisList, pivot: []const u8, value: PrimitiveValue) !?usize {
        var current = self.list.first;
        while (current) |node| {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            if (primitive_eql_slice(list_node.data, pivot)) {
                const new_node = try self.allocator.create(ZedisListNode);
                new_node.* = .{ .data = value };
                // insert new_node before node
                new_node.node.prev = node.prev;
                new_node.node.next = node;
                if (node.prev) |prev| {
                    prev.next = &new_node.node;
                } else {
                    self.list.first = &new_node.node;
                }
                node.prev = &new_node.node;
                self.cached_len += 1;
                if (self.list.last == null) self.list.last = &new_node.node;
                return self.cached_len;
            }
            current = node.next;
        }
        return null;
    }

    pub fn insert_after(self: *ZedisList, pivot: []const u8, value: PrimitiveValue) !?usize {
        var current = self.list.first;
        while (current) |node| {
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            if (primitive_eql_slice(list_node.data, pivot)) {
                const new_node = try self.allocator.create(ZedisListNode);
                new_node.* = .{ .data = value };
                // insert new_node after node
                new_node.node.prev = node;
                new_node.node.next = node.next;
                if (node.next) |next| {
                    next.prev = &new_node.node;
                } else {
                    self.list.last = &new_node.node;
                }
                node.next = &new_node.node;
                self.cached_len += 1;
                return self.cached_len;
            }
            current = node.next;
        }
        return null;
    }
};
