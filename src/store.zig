const std = @import("std");
const SafeMemoryPool = @import("./safe_memory_pool.zig");
const simd = @import("./simd.zig");

// Optimal load factor
const optimal_max_load_percentage = 75;

const OptimizedHashMap = std.ArrayHashMapUnmanaged([]const u8, ZedisObject, StringContext, true);

// Memory pool sizes optimized for Redis workloads
const SMALL_STRING_SIZE = 32; // Redis keys are often small
const MEDIUM_STRING_SIZE = 128; // Medium-sized values
const LARGE_STRING_SIZE = 512; // Larger values but still pooled

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
    data: [23]u8, // Inline storage - increased from 15 to 23 bytes
    len: u8, // Actual length

    pub fn fromSlice(str: []const u8) ShortString {
        var ss: ShortString = .{ .data = undefined, .len = @intCast(str.len) };
        @memcpy(ss.data[0..str.len], str);
        // Zero remaining bytes for consistent hashing
        @memset(ss.data[str.len..], 0);
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

pub const ZedisObject = struct {
    value: ZedisValue,
};

const StringContext = struct {
    pub fn hash(self: @This(), s: []const u8) u32 {
        _ = self;
        // Redis-optimized hash function for typical key patterns
        return redisOptimizedHash(s);
    }

    pub fn eql(self: @This(), a: []const u8, b: []const u8, b_index: usize) bool {
        _ = self;
        _ = b_index;
        // Quick length check first
        if (a.len != b.len) return false;
        // For interned strings, this becomes pointer comparison
        if (a.ptr == b.ptr) return true;

        // Use SIMD for longer strings (Redis keys can be long)
        if (a.len >= 16) {
            return simd.simdStringEql(a, b);
        }

        return std.mem.eql(u8, a, b);
    }
};

/// Redis-optimized hash function for common key patterns
fn redisOptimizedHash(s: []const u8) u32 {
    if (s.len == 0) return 0;

    // Fast path for very short keys
    if (s.len <= 4) {
        var hash: u32 = 0;
        for (s, 0..) |byte, i| {
            hash |= @as(u32, byte) << @intCast(i * 8);
        }
        return hash;
    }

    // Optimized for Redis key patterns:
    // - "user:123", "session:abc", "cache:key:value"
    // - Often have colons as separators
    // - Numbers are common
    var hash: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
    const prime: u64 = 0x00000100000001b3; // FNV-1a prime

    // Process 8 bytes at a time for better performance
    var i: usize = 0;
    while (i + 8 <= s.len) {
        const chunk = std.mem.readInt(u64, s[i..][0..8], .little);
        hash ^= chunk;
        hash *%= prime;
        i += 8;
    }

    // Handle remaining bytes
    while (i < s.len) {
        hash ^= s[i];
        hash *%= prime;
        i += 1;
    }

    return @truncate(hash);
}

pub const Store = struct {
    base_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    // Cache hash map
    map: OptimizedHashMap,
    // Expiration hash map
    expiration_map: std.StringHashMapUnmanaged(i64),

    // Map of interned strings
    interned_strings: std.StringHashMapUnmanaged([]const u8),

    // Hybrid memory pools for different string sizes
    small_pool: SafeMemoryPool, // 32 bytes - for keys
    medium_pool: SafeMemoryPool, // 128 bytes - for small values
    large_pool: SafeMemoryPool, // 512 bytes - for medium values

    // Statistics for pool effectiveness
    pool_hits: std.atomic.Value(u64),
    pool_misses: std.atomic.Value(u64),

    /// Check if we need to resize to maintain optimal load factor
    inline fn maybeResize(self: *Store) !void {
        const current_load = (self.map.count() * 100) / self.map.capacity();
        if (current_load > optimal_max_load_percentage) {
            const new_capacity = self.map.capacity() * 2;
            try self.map.ensureTotalCapacity(self.base_allocator, new_capacity);
        }
    }

    pub fn init(allocator: std.mem.Allocator) Store {
        // Increased initial capacity to reduce rehashing
        const initial_capacity = 4096;
        var map: OptimizedHashMap = .{};
        map.ensureTotalCapacity(allocator, initial_capacity) catch unreachable;

        return .{
            .base_allocator = allocator,
            .allocator = allocator,
            .map = map,
            .expiration_map = .{},
            .interned_strings = .{},
            .small_pool = SafeMemoryPool.init(allocator, SMALL_STRING_SIZE),
            .medium_pool = SafeMemoryPool.init(allocator, MEDIUM_STRING_SIZE),
            .large_pool = SafeMemoryPool.init(allocator, LARGE_STRING_SIZE),
            .pool_hits = std.atomic.Value(u64).init(0),
            .pool_misses = std.atomic.Value(u64).init(0),
        };
    }

    // Frees all memory associated with the store.
    pub fn deinit(self: *Store) void {
        // Free all values in the main map
        var map_it = self.map.iterator();
        while (map_it.next()) |entry| {
            // Don't free keys - they're managed by interned_strings
            // Free values based on their type
            switch (entry.value_ptr.*.value) {
                .string => |str| {
                    if (str.len > 0) self.smartFree(str);
                },
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
            }
        }
        self.map.deinit(self.base_allocator);

        // Free interned strings
        var intern_it = self.interned_strings.iterator();
        while (intern_it.next()) |entry| {
            if (entry.key_ptr.*.len > 0) self.smartFree(entry.key_ptr.*);
        }
        self.interned_strings.deinit(self.base_allocator);

        self.expiration_map.deinit(self.base_allocator);

        // Clean up memory pools
        self.small_pool.deinit();
        self.medium_pool.deinit();
        self.large_pool.deinit();
    }

    pub inline fn size(self: Store) u32 {
        return @intCast(self.map.count());
    }

    fn internString(self: *Store, str: []const u8) ![]const u8 {
        const gop = try self.interned_strings.getOrPut(self.base_allocator, str);
        if (!gop.found_existing) {
            const owned_str = try self.dupeString(str);
            gop.key_ptr.* = owned_str;
            gop.value_ptr.* = owned_str;
        }
        return gop.value_ptr.*;
    }

    /// Smart allocation using memory pools based on size
    pub inline fn smartAlloc(self: *Store, len: usize) ![]u8 {
        if (len <= SMALL_STRING_SIZE) {
            if (self.small_pool.alloc(len)) |result| {
                _ = self.pool_hits.fetchAdd(1, .monotonic);
                return result;
            } else |_| {}
        } else if (len <= MEDIUM_STRING_SIZE) {
            if (self.medium_pool.alloc(len)) |result| {
                _ = self.pool_hits.fetchAdd(1, .monotonic);
                return result;
            } else |_| {}
        } else if (len <= LARGE_STRING_SIZE) {
            if (self.large_pool.alloc(len)) |result| {
                _ = self.pool_hits.fetchAdd(1, .monotonic);
                return result;
            } else |_| {}
        }

        // Fallback to base allocator
        _ = self.pool_misses.fetchAdd(1, .monotonic);
        return try self.base_allocator.alloc(u8, len);
    }

    /// Smart deallocation that returns memory to appropriate pool
    pub inline fn smartFree(self: *Store, slice: []const u8) void {
        if (slice.len == 0) return;

        // Try pools in order of likelihood
        if (slice.len <= SMALL_STRING_SIZE and self.small_pool.owns(slice)) {
            self.small_pool.free(slice);
        } else if (slice.len <= MEDIUM_STRING_SIZE and self.medium_pool.owns(slice)) {
            self.medium_pool.free(slice);
        } else if (slice.len <= LARGE_STRING_SIZE and self.large_pool.owns(slice)) {
            self.large_pool.free(slice);
        } else {
            // Not from pools, use base allocator
            self.base_allocator.free(slice);
        }
    }

    /// Duplicate a string using smart allocation
    pub inline fn dupeString(self: *Store, str: []const u8) ![]u8 {
        const buf = try self.smartAlloc(str.len);
        @memcpy(buf, str);
        return buf;
    }

    fn setString(self: *Store, key: []const u8, value: []const u8) !void {
        // Automatically use ShortString for small strings to avoid allocation
        const zedis_value: ZedisValue = if (value.len <= 23)
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
        // Check if we need to resize before adding new entries
        try self.maybeResize();

        const interned_key = try self.internString(key);
        const gop = try self.map.getOrPut(self.base_allocator, interned_key);

        // Free old value if key existed
        if (gop.found_existing) {
            switch (gop.value_ptr.value) {
                .string => |str| {
                    if (str.len > 0) self.smartFree(str);
                },
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
            }
        }
        // Key is already interned, no need to duplicate again
        gop.key_ptr.* = interned_key;

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
        if (self.map.getPtr(key)) |obj_ptr| {
            // Free the value based on its type
            switch (obj_ptr.value) {
                .string => |str| {
                    if (str.len > 0) self.smartFree(str);
                },
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
            }

            // Remove from maps
            _ = self.map.swapRemove(key);
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
            const interned_key = try self.internString(key);
            try self.expiration_map.put(self.base_allocator, interned_key, time);
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

    /// Get memory pool statistics
    pub fn getPoolStats(self: *Store) PoolStats {
        const hits = self.pool_hits.load(.acquire);
        const misses = self.pool_misses.load(.acquire);
        const total = hits + misses;

        return PoolStats{
            .pool_hits = hits,
            .pool_misses = misses,
            .hit_rate = if (total > 0) (@as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total))) * 100.0 else 0.0,
            .small_pool_allocations = self.small_pool.allocations.count(),
            .medium_pool_allocations = self.medium_pool.allocations.count(),
            .large_pool_allocations = self.large_pool.allocations.count(),
        };
    }

    /// Reset pool statistics
    pub fn resetPoolStats(self: *Store) void {
        self.pool_hits.store(0, .release);
        self.pool_misses.store(0, .release);
    }
};

pub const PoolStats = struct {
    pool_hits: u64,
    pool_misses: u64,
    hit_rate: f64,
    small_pool_allocations: u32,
    medium_pool_allocations: u32,
    large_pool_allocations: u32,
};
