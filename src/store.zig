const std = @import("std");
const SafeMemoryPool = @import("./safe_memory_pool.zig");
const simd = @import("./simd.zig");
const PrimitiveValue = @import("types.zig").PrimitiveValue;
const ZedisList = @import("list.zig").ZedisList;
const ZedisListNode = @import("list.zig").ZedisListNode;
const ts_module = @import("time_series.zig");
const TimeSeries = ts_module.TimeSeries;
const CityHash64 = std.hash.CityHash64;
const string_match = @import("./util/string_match.zig").string_match;

const assert = std.debug.assert;

// Optimal load factor
const optimal_max_load_percentage = 75;

const OptimizedHashMap = std.ArrayHashMapUnmanaged([]const u8, ZedisObject, StringContext, true);

// Memory pool sizes optimized for Redis workloads
const SMALL_STRING_SIZE = 32; // Redis keys are often small
const MEDIUM_STRING_SIZE = 128; // Medium-sized values
const LARGE_STRING_SIZE = 512; // Larger values but still pooled

pub const ValueType = enum(u8) {
    string = 0,
    int,
    list,
    short_string,
    time_series,

    pub fn toRdbOpcode(self: ValueType) u8 {
        return @intFromEnum(self);
    }

    pub fn fromOpCode(num: u8) ValueType {
        return @enumFromInt(num);
    }
};

pub const ShortString = struct {
    data: [23]u8, // Inline storage - increased from 15 to 23 bytes
    len: u8, // Actual length

    pub fn fromSlice(str: []const u8) ShortString {
        assert(str.len <= 23);
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
    time_series: TimeSeries,
};

pub const ZedisObject = struct {
    value: ZedisValue,
    last_access: u64 = 0,
};

const StringContext = struct {
    pub fn hash(self: @This(), s: []const u8) u32 {
        _ = self;
        return @truncate(CityHash64.hash(s));
    }

    pub fn eql(self: @This(), a: []const u8, b: []const u8, b_index: usize) bool {
        _ = self;
        _ = b_index;
        // Quick length check first
        if (a.len != b.len) return false;
        // For interned strings, this becomes pointer comparison
        if (a.ptr == b.ptr) return true;

        return simd.simdStringEql(a, b);
    }
};

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

    access_counter: std.atomic.Value(u64),

    /// Check if we need to resize to maintain optimal load factor
    inline fn maybeResize(self: *Store) !void {
        const current_load = (self.map.count() * 100) / self.map.capacity();
        if (current_load > optimal_max_load_percentage) {
            const new_capacity = self.map.capacity() * 2;
            try self.map.ensureTotalCapacity(self.base_allocator, new_capacity);
        }
    }

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize) Store {
        var map: OptimizedHashMap = .{};
        map.ensureTotalCapacity(allocator, initial_capacity) catch unreachable;

        return .{
            .base_allocator = allocator,
            .allocator = allocator,
            .map = map,
            .expiration_map = .{},
            .interned_strings = .{},
            .small_pool = .init(allocator, SMALL_STRING_SIZE),
            .medium_pool = .init(allocator, MEDIUM_STRING_SIZE),
            .large_pool = .init(allocator, LARGE_STRING_SIZE),
            .pool_hits = .init(0),
            .pool_misses = .init(0),
            .access_counter = .init(0),
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
                .time_series => |*ts| ts.deinit(),
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
        assert(str.len > 0);
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
        assert(len > 0);
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
        assert(str.len > 0);
        const buf = try self.smartAlloc(str.len);
        @memcpy(buf, str);
        return buf;
    }

    fn setString(self: *Store, key: []const u8, value: []const u8) !void {
        assert(value.len > 0);
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
        // Handle empty string as a valid value (Redis allows this)
        if (value.len == 0) {
            const zedis_value: ZedisValue = .{ .short_string = ShortString.fromSlice(value) };
            const zedis_object = ZedisObject{ .value = zedis_value };
            try self.putObject(key, zedis_object);
            return;
        }

        // Try to parse as integer for automatic type optimization
        if (std.fmt.parseInt(i64, value, 10)) |int_value| {
            try self.putObject(key, .{ .value = .{ .int = int_value } });
        } else |_| {
            try self.setString(key, value);
        }
    }

    /// Update/overwrite an existing key or insert if not present
    pub inline fn putObject(self: *Store, key: []const u8, object: ZedisObject) !void {
        assert(key.len > 0);
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
                .time_series => return error.AlreadyExists,
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
            .time_series => {},
        }

        // Update the entry
        gop.value_ptr.* = new_object;
    }

    // Delete a key from the store
    pub fn delete(self: *Store, key: []const u8) bool {
        assert(key.len > 0);
        if (self.map.getPtr(key)) |obj_ptr| {
            // Free the value based on its type
            switch (obj_ptr.value) {
                .string => |str| {
                    if (str.len > 0) self.smartFree(str);
                },
                .int => {},
                .list => |*list| @constCast(list).deinit(),
                .short_string => {},
                .time_series => |*ts| ts.deinit(),
            }

            // Remove from maps
            _ = self.map.swapRemove(key);
            _ = self.expiration_map.remove(key);
            return true;
        }
        return false;
    }

    pub inline fn exists(self: Store, key: []const u8) bool {
        assert(key.len > 0);
        return self.map.contains(key);
    }

    pub inline fn getType(self: Store, key: []const u8) ?ValueType {
        assert(key.len > 0);
        if (self.map.getPtr(key)) |obj| {
            return std.meta.activeTag(obj.value);
        }
        return null;
    }

    pub inline fn get(self: *Store, key: []const u8) ?*const ZedisObject {
        assert(key.len > 0);
        if (self.isExpired(key)) {
            _ = self.delete(key);
            return null;
        }
        if (self.map.getPtr(key)) |obj| {
            obj.last_access = self.access_counter.fetchAdd(1, .monotonic);
            return obj;
        }
        return null;
    }

    pub fn keys(self: Store, allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (pattern.len == 0 or string_match(pattern, key)) {
                try result.append(allocator, key);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getList(self: Store, key: []const u8) !?*ZedisList {
        assert(key.len > 0);
        if (self.map.getPtr(key)) |obj_ptr| {
            switch (obj_ptr.value) {
                .list => |*list| return list,
                else => return error.WrongType,
            }
        }
        return null;
    }

    pub fn getTimeSeries(self: Store, key: []const u8) !?*TimeSeries {
        assert(key.len > 0);
        if (self.map.getPtr(key)) |obj_ptr| {
            switch (obj_ptr.value) {
                .time_series => |*ts| return ts,
                else => return error.WrongType,
            }
        }
        return null;
    }

    pub fn createList(self: *Store, key: []const u8) !*ZedisList {
        assert(key.len > 0);
        // Create list - error if key already exists
        const list: ZedisList = .init(self.base_allocator);
        const zedis_object: ZedisObject = .{ .value = .{ .list = list } };

        try self.putObject(key, zedis_object);

        return &self.map.getPtr(key).?.value.list;
    }

    pub fn getSetList(self: *Store, key: []const u8) !*ZedisList {
        assert(key.len > 0);
        const list = try self.getList(key);
        if (list == null) {
            return try self.createList(key);
        }
        return list.?;
    }

    pub fn expire(self: *Store, key: []const u8, time: i64) !bool {
        assert(key.len > 0);
        assert(time > 0);
        if (self.map.contains(key)) {
            const interned_key = try self.internString(key);
            try self.expiration_map.put(self.base_allocator, interned_key, time);
            return true;
        }
        return false;
    }

    pub inline fn isExpired(self: Store, key: []const u8) bool {
        assert(key.len > 0);
        if (self.expiration_map.get(key)) |expiration_time| {
            return std.time.milliTimestamp() > expiration_time;
        }
        return false;
    }

    pub inline fn getTtl(self: Store, key: []const u8) ?i64 {
        assert(key.len > 0);
        return self.expiration_map.get(key);
    }

    pub inline fn persist(self: *Store, key: []const u8) bool {
        assert(key.len > 0);
        return self.expiration_map.remove(key);
    }

    pub inline fn randomKey(self: *Store, random: std.Random) ?[]const u8 {
        const total_keys = self.map.count();
        if (total_keys == 0) return null;

        const random_idx = random.intRangeAtMost(usize, 0, total_keys - 1);

        const key = self.map.keys()[random_idx];

        return key;
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

    /// Sample random keys and return the least recently used one (approximate LRU)
    /// If volatile_only is true, only samples keys with expiration set (volatile-lru policy)
    pub fn sampleLRUKey(self: *Store, sample_size: usize, volatile_only: bool) ?[]const u8 {
        // Check appropriate map based on policy
        const total_keys = if (volatile_only) self.expiration_map.count() else self.map.count();
        if (total_keys == 0) return null;

        var oldest_key: ?[]const u8 = null;
        var oldest_access: u64 = std.math.maxInt(u64);

        // Use a simple PRNG for sampling
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
        const random = prng.random();

        // Sample up to sample_size random keys
        var samples_taken: usize = 0;
        while (samples_taken < sample_size and samples_taken < total_keys) : (samples_taken += 1) {
            // Get random index
            const random_idx = random.intRangeLessThan(usize, 0, total_keys);

            if (volatile_only) {
                // Sample from keys with expiration
                var it = self.expiration_map.iterator();
                var current_idx: usize = 0;
                while (it.next()) |entry| {
                    if (current_idx == random_idx) {
                        const key = entry.key_ptr.*;
                        // Get the object to check its access time
                        if (self.map.getPtr(key)) |obj| {
                            if (obj.last_access < oldest_access) {
                                oldest_access = obj.last_access;
                                oldest_key = key;
                            }
                        }
                        break;
                    }
                    current_idx += 1;
                }
            } else {
                // Sample from all keys
                var it = self.map.iterator();
                var current_idx: usize = 0;
                while (it.next()) |entry| {
                    if (current_idx == random_idx) {
                        const obj = entry.value_ptr;
                        if (obj.last_access < oldest_access) {
                            oldest_access = obj.last_access;
                            oldest_key = entry.key_ptr.*;
                        }
                        break;
                    }
                    current_idx += 1;
                }
            }
        }

        return oldest_key;
    }

    pub fn createTimeSeries(self: *Store, key: []const u8, ts: TimeSeries) !void {
        assert(key.len > 0);
        try self.putObject(key, .{ .value = .{ .time_series = ts } });
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
