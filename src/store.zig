const std = @import("std");

pub const ValueType = enum(u8) {
    string = 0,
    int = 1,
    list = 2,
    short_string = 3,

    pub fn toRdbOpcode(self: ValueType) u8 {
        return @intFromEnum(self);
    }

    pub fn fromOpCode(num: u8) ValueType {
        return @enumFromInt(num);
    }
};

pub const StoreError = error{
    KeyNotFound,
    WrongType,
    NotAnInteger,
    KeyAlreadyExists,
};

pub const PrimitiveValue = union(enum) {
    string: []const u8,
    int: i64,
};

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

    pub fn popFirst(self: *ZedisList) ?PrimitiveValue {
        const node = self.list.popFirst() orelse return null;
        const list_node: *ZedisListNode = @fieldParentPtr("node", node);
        const value = list_node.data;
        self.allocator.destroy(list_node);
        self.cached_len -= 1;
        return value;
    }

    pub fn pop(self: *ZedisList) ?PrimitiveValue {
        const node = self.list.pop() orelse return null;
        const list_node: *ZedisListNode = @fieldParentPtr("node", node);
        const value = list_node.data;
        self.allocator.destroy(list_node);
        self.cached_len -= 1;
        return value;
    }

    pub fn getByIndex(self: *const ZedisList, index: i64) ?PrimitiveValue {
        const list_len = self.cached_len;
        if (list_len == 0) return null;

        // Convert negative index to positive
        const actual_index: usize = if (index < 0) blk: {
            const neg_offset = @as(usize, @intCast(-index));
            if (neg_offset > list_len) return null;
            break :blk list_len - neg_offset;
        } else blk: {
            const pos_index = @as(usize, @intCast(index));
            if (pos_index >= list_len) return null;
            break :blk pos_index;
        };

        // O(1) optimization for first index
        if (actual_index == 0) {
            const node = self.list.first orelse return null;
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            return list_node.data;
        }

        // O(1) optimization for last index
        if (actual_index == list_len - 1) {
            const node = self.list.last orelse return null;
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            return list_node.data;
        }

        // O(n) traversal for middle indices
        var current = self.list.first;
        var i: usize = 0;
        while (current) |node| {
            if (i == actual_index) {
                const list_node: *ZedisListNode = @fieldParentPtr("node", node);
                return list_node.data;
            }
            current = node.next;
            i += 1;
        }
        return null;
    }

    pub fn setByIndex(self: *ZedisList, index: i64, value: PrimitiveValue) !void {
        const list_len = self.cached_len;
        if (list_len == 0) return StoreError.KeyNotFound;

        // Convert negative index to positive
        const actual_index: usize = if (index < 0) blk: {
            const neg_offset = @as(usize, @intCast(-index));
            if (neg_offset > list_len) return StoreError.KeyNotFound;
            break :blk list_len - neg_offset;
        } else blk: {
            const pos_index = @as(usize, @intCast(index));
            if (pos_index >= list_len) return StoreError.KeyNotFound;
            break :blk pos_index;
        };

        // O(1) optimization for first index
        if (actual_index == 0) {
            const node = self.list.first orelse return StoreError.KeyNotFound;
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            list_node.data = value;
            return;
        }

        // O(1) optimization for last index
        if (actual_index == list_len - 1) {
            const node = self.list.last orelse return StoreError.KeyNotFound;
            const list_node: *ZedisListNode = @fieldParentPtr("node", node);
            list_node.data = value;
            return;
        }

        // O(n) traversal for middle indices
        var current = self.list.first;
        var i: usize = 0;
        while (current) |node| {
            if (i == actual_index) {
                const list_node: *ZedisListNode = @fieldParentPtr("node", node);
                list_node.data = value;
                return;
            }
            current = node.next;
            i += 1;
        }
        return StoreError.KeyNotFound;
    }
};

pub const ShortString = struct {
    data: [15]u8, // Inline storage
    len: u8, // Actual length

    pub fn fromSlice(str: []const u8) ShortString {
        var ss: ShortString = .{ .data = undefined, .len = @intCast(str.len) };
        @memcpy(ss.data[0..str.len], str);
        return ss;
    }

    pub fn asSlice(self: *const ShortString) []const u8 {
        return self.data[0..self.len];
    }
};

pub const ZedisValue = union(ValueType) {
    string: []const u8,
    int: i64,
    list: ZedisList,
    short_string: ShortString,
};

pub const ZedisObject = struct { value: ZedisValue };

pub const Store = struct {
    base_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    // The HashMap stores string keys and string values.
    map: std.StringHashMapUnmanaged(ZedisObject),
    // Separate map for expirations
    expiration_map: std.StringHashMapUnmanaged(i64),

    pool_32: std.heap.MemoryPool([32]u8),
    pool_64: std.heap.MemoryPool([64]u8),
    pool_128: std.heap.MemoryPool([128]u8),

    // Initializes the store.
    pub fn init(allocator: std.mem.Allocator) Store {
        const initial_capacity = 1024;
        var map: std.StringHashMapUnmanaged(ZedisObject) = .{};
        map.ensureTotalCapacity(allocator, initial_capacity) catch unreachable;

        return .{
            .base_allocator = allocator,
            .allocator = allocator,
            .map = map,
            .expiration_map = .{},
            .pool_32 = std.heap.MemoryPool([32]u8).init(allocator),
            .pool_64 = std.heap.MemoryPool([64]u8).init(allocator),
            .pool_128 = std.heap.MemoryPool([128]u8).init(allocator),
        };
    }

    // Frees all memory associated with the store.
    pub fn deinit(self: *Store) void {
        var map_it = self.map.iterator();
        while (map_it.next()) |entry| {
            self.freeString(entry.key_ptr.*);
            // Free values based on their type
            switch (entry.value_ptr.*.value) {
                .string => |str| self.freeString(str),
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
            }
        }
        self.map.deinit(self.base_allocator);
        self.expiration_map.deinit(self.base_allocator);
        self.pool_32.deinit();
        self.pool_64.deinit();
        self.pool_128.deinit();
    }

    pub inline fn size(self: Store) u32 {
        return self.map.count();
    }

    /// Allocate a string buffer using pools for common sizes
    inline fn allocString(self: *Store, len: usize) ![]u8 {
        if (len <= 32) {
            const buf = try self.pool_32.create();
            return buf[0..len];
        } else if (len <= 64) {
            const buf = try self.pool_64.create();
            return buf[0..len];
        } else if (len <= 128) {
            const buf = try self.pool_128.create();
            return buf[0..len];
        }
        return try self.base_allocator.alloc(u8, len);
    }

    /// Free a string buffer, returning to pool if applicable
    inline fn freeString(self: *Store, str: []const u8) void {
        if (str.len <= 32) {
            const array_ptr: *align(8) [32]u8 = @ptrCast(@alignCast(@constCast(str.ptr)));
            self.pool_32.destroy(array_ptr);
        } else if (str.len <= 64) {
            const array_ptr: *align(8) [64]u8 = @ptrCast(@alignCast(@constCast(str.ptr)));
            self.pool_64.destroy(array_ptr);
        } else if (str.len <= 128) {
            const array_ptr: *align(8) [128]u8 = @ptrCast(@alignCast(@constCast(str.ptr)));
            self.pool_128.destroy(array_ptr);
        } else {
            self.base_allocator.free(str);
        }
    }

    /// Duplicate a string using pools when possible
    inline fn dupeString(self: *Store, str: []const u8) ![]u8 {
        const buf = try self.allocString(str.len);
        @memcpy(buf, str);
        return buf;
    }

    fn setString(self: *Store, key: []const u8, value: []const u8) !void {
        // Automatically use ShortString for small strings to avoid allocation
        const zedis_value: ZedisValue = if (value.len <= 15)
            .{ .short_string = ShortString.fromSlice(value) }
        else
            .{ .string = value };
        const zedis_object = ZedisObject{ .value = zedis_value };
        try self.putObject(key, zedis_object);
    }

    pub fn setInt(self: *Store, key: []const u8, value: i64) !void {
        try self.putObject(key, .{ .value = .{ .int = value } });
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        // Try to parse as integer for automatic type optimization
        if (std.fmt.parseInt(i64, value, 10)) |int_value| {
            try self.putObject(key, .{ .value = .{ .int = int_value } });
        } else |_| {
            try self.setString(key, value);
        }
    }

    /// Update/overwrite an existing key or insert if not present
    pub inline fn putObject(self: *Store, key: []const u8, object: ZedisObject) !void {
        const gop = try self.map.getOrPut(self.base_allocator, key);

        // Free old value if key existed
        if (gop.found_existing) {
            switch (gop.value_ptr.value) {
                .string => |str| self.freeString(str),
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
            }
        } else {
            // New key - allocate copy using pool allocator
            gop.key_ptr.* = try self.dupeString(key);
        }

        // Build the new object with allocated values
        var new_object = object;
        switch (object.value) {
            .string => |str| {
                const value_copy = try self.dupeString(str);
                new_object.value = .{ .string = value_copy };
            },
            .int => {}, // No allocation needed
            .list => {}, // List is moved directly
            .short_string => {}, // No allocation needed - stored inline
        }

        // Update the entry
        gop.value_ptr.* = new_object;
    }

    // Delete a key from the store
    pub fn delete(self: *Store, key: []const u8) bool {
        if (self.map.fetchRemove(key)) |kv| {
            self.freeString(kv.key);
            // Free the value based on its type
            switch (kv.value.value) {
                .string => |str| self.freeString(str),
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
            }
            // Remove from expiration map if present
            _ = self.expiration_map.remove(key);
            return true;
        }
        return false;
    }

    pub inline fn exists(self: Store, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub inline fn getType(self: Store, key: []const u8) ?ValueType {
        if (self.map.getPtr(key)) |obj| {
            return std.meta.activeTag(obj.value);
        }
        return null;
    }

    pub inline fn get(self: *Store, key: []const u8) ?*const ZedisObject {
        if (self.isExpired(key)) {
            _ = self.delete(key);
            return null;
        }
        return self.map.getPtr(key);
    }

    pub fn getList(self: Store, key: []const u8) !?*ZedisList {
        if (self.map.getPtr(key)) |obj_ptr| {
            switch (obj_ptr.value) {
                .list => |*list| return list,
                else => return StoreError.WrongType,
            }
        }
        return null;
    }

    pub fn createList(self: *Store, key: []const u8) !*ZedisList {
        // Create list - error if key already exists
        const list: ZedisList = .init(self.base_allocator);
        const zedis_object: ZedisObject = .{ .value = .{ .list = list } };

        try self.putObject(key, zedis_object);

        return &self.map.getPtr(key).?.value.list;
    }

    pub fn getSetList(self: *Store, key: []const u8) !*ZedisList {
        const list = try self.getList(key);
        if (list == null) {
            return try self.createList(key);
        }
        return list.?;
    }

    pub fn expire(self: *Store, key: []const u8, time: i64) !bool {
        if (self.map.contains(key)) {
            try self.expiration_map.put(self.base_allocator, key, time);
            return true;
        }
        return false;
    }

    pub inline fn isExpired(self: Store, key: []const u8) bool {
        if (self.expiration_map.get(key)) |expiration_time| {
            return std.time.milliTimestamp() > expiration_time;
        }
        return false;
    }

    pub inline fn getTtl(self: Store, key: []const u8) ?i64 {
        return self.expiration_map.get(key);
    }
};
