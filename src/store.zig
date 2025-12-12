const std = @import("std");
const PrimitiveValue = @import("types.zig").PrimitiveValue;
const ZedisList = @import("list.zig").ZedisList;
const ZedisListNode = @import("list.zig").ZedisListNode;
const ts_module = @import("time_series.zig");
const TimeSeries = ts_module.TimeSeries;
const CityHash64 = std.hash.CityHash64;
const Io = std.Io;
const string_match = @import("./util/string_match.zig").string_match;

const assert = std.debug.assert;

// Optimal load factor
const optimal_max_load_percentage = 80;

const OptimizedHashMap = std.StringHashMapUnmanaged(ZedisObject);

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
    list: *ZedisList,
    short_string: ShortString,
    time_series: *TimeSeries,
};

pub const ZedisObject = struct {
    value: ZedisValue,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    // Cache hash map
    map: OptimizedHashMap,
    // Expiration hash map
    expiration_map: std.StringHashMapUnmanaged(i64),

    io: Io,

    access_counter: std.atomic.Value(u64),

    // Tracking for maintenance
    deletions_since_rehash: usize,
    last_maintenance_check: i64,

    /// Check if we need to resize to maintain optimal load factor
    inline fn maybeResize(self: *Store) !void {
        const current_load = (self.map.count() * 100) / self.map.capacity();
        if (current_load > optimal_max_load_percentage) {
            const new_capacity = self.map.capacity() * 2;
            try self.map.ensureTotalCapacity(self.allocator, new_capacity);
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: Io, initial_capacity: u32) Store {
        var map: OptimizedHashMap = .empty;
        map.ensureTotalCapacity(allocator, initial_capacity) catch unreachable;

        return .{
            .allocator = allocator,
            .map = map,
            .expiration_map = .{},
            .access_counter = .init(0),
            .deletions_since_rehash = 0,
            .last_maintenance_check = 0,
            .io = io,
        };
    }

    // Frees all memory associated with the store.
    pub fn deinit(self: *Store) void {
        // Free all keys and values in the main map
        var map_it = self.map.iterator();
        while (map_it.next()) |entry| {
            // Free the key
            if (entry.key_ptr.*.len > 0) self.allocator.free(entry.key_ptr.*);

            // Free the value
            switch (entry.value_ptr.*.value) {
                .string => |str| {
                    if (str.len > 0) self.allocator.free(str);
                },
                .int => {},
                .list => |list_ptr| {
                    list_ptr.deinit();
                    self.allocator.destroy(list_ptr);
                },
                .short_string => {},
                .time_series => |ts_ptr| {
                    ts_ptr.deinit();
                    self.allocator.destroy(ts_ptr);
                },
            }
        }
        self.map.deinit(self.allocator);

        self.expiration_map.deinit(self.allocator);
    }

    pub inline fn size(self: Store) u32 {
        return @intCast(self.map.count());
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

        const gop = try self.map.getOrPut(self.allocator, key);

        // Free old value if key existed
        if (gop.found_existing) {
            switch (gop.value_ptr.value) {
                .string => |str| {
                    if (str.len > 0) self.allocator.free(str);
                },
                .int => {},
                .list => |list_ptr| {
                    list_ptr.deinit();
                    self.allocator.destroy(list_ptr);
                },
                .short_string => {},
                .time_series => return error.AlreadyExists,
            }
        } else {
            // New key - need to duplicate it for the HashMap to own
            const owned_key = try self.allocator.dupe(u8, key);
            gop.key_ptr.* = owned_key;
        }

        // Build the new object with allocated values
        var new_object = object;
        switch (object.value) {
            .string => |str| {
                const value_copy = try self.allocator.dupe(u8, str);
                new_object.value = .{ .string = value_copy };
            },
            .int => {}, // No allocation needed
            .list => {}, // List is moved directly
            .short_string => {}, // No allocation needed - stored inline
            .time_series => {},
        }

        // Update the entry
        gop.value_ptr.* = new_object;

        // Maybe run maintenance if thresholds are met
        self.maybeMaintenance();
    }

    // Delete a key from the store
    pub fn delete(self: *Store, key: []const u8) bool {
        assert(key.len > 0);

        if (self.map.getKey(key)) |stored_key| {
            if (self.map.getPtr(key)) |obj_ptr| {
                // Free the value based on its type
                switch (obj_ptr.value) {
                    .string => |str| {
                        if (str.len > 0) self.allocator.free(str);
                    },
                    .int => {},
                    .list => |list_ptr| {
                        list_ptr.deinit();
                        self.allocator.destroy(list_ptr);
                    },
                    .short_string => {},
                    .time_series => |ts_ptr| {
                        ts_ptr.deinit();
                        self.allocator.destroy(ts_ptr);
                    },
                }

                // Remove from maps
                _ = self.map.remove(key);
                _ = self.expiration_map.remove(key);

                // Free the key (now that it's no longer in any map)
                if (stored_key.len > 0) self.allocator.free(stored_key);

                // Track deletion for maintenance
                self.deletions_since_rehash += 1;

                // Maybe run maintenance if thresholds are met
                self.maybeMaintenance();

                return true;
            }
        }
        return false;
    }

    pub inline fn exists(self: *Store, key: []const u8) bool {
        assert(key.len > 0);

        // Check existence first
        if (!self.map.contains(key)) return false;

        // Check expiration
        if (self.expiration_map.get(key)) |expiration_time| {
            const timestamp = Io.Clock.real.now(self.io) catch unreachable;
            const now = timestamp.toMilliseconds();
            if (now > expiration_time) {
                _ = self.delete(key);
                return false;
            }
        }

        return true;
    }

    pub inline fn getType(self: *Store, key: []const u8) ?ValueType {
        assert(key.len > 0);

        // Check existence first
        const obj_ptr = self.map.getPtr(key) orelse return null;

        // Check expiration before returning type
        if (self.expiration_map.get(key)) |expiration_time| {
            if (std.time.milliTimestamp() > expiration_time) {
                _ = self.delete(key);
                return null;
            }
        }

        return std.meta.activeTag(obj_ptr.value);
    }

    pub inline fn get(self: *Store, key: []const u8) ?*const ZedisObject {
        assert(key.len > 0);
        // Check existence first (Redis-style optimization)
        // This avoids expiration lookup for non-existent keys
        const obj_ptr = self.map.getPtr(key) orelse return null;

        // Only check expiration if key exists AND has TTL
        if (self.expiration_map.get(key)) |expiration_time| {
            const timestamp = Io.Clock.real.now(self.io) catch unreachable;
            const now = timestamp.toMilliseconds();
            if (now > expiration_time) {
                _ = self.delete(key);
                return null;
            }
        }

        return obj_ptr;
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

    pub fn getList(self: *Store, key: []const u8) !?*ZedisList {
        assert(key.len > 0);

        // Check existence first
        const obj_ptr = self.map.getPtr(key) orelse return null;

        // Check expiration before type checking
        if (self.expiration_map.get(key)) |expiration_time| {
            const timestamp = Io.Clock.real.now(self.io) catch unreachable;
            const now = timestamp.toMilliseconds();
            if (now > expiration_time) {
                _ = self.delete(key);
                return null;
            }
        }

        // Type check and return
        switch (obj_ptr.value) {
            .list => |list_ptr| return list_ptr,
            else => return error.WrongType,
        }
    }

    pub fn getTimeSeries(self: *Store, key: []const u8) !?*TimeSeries {
        assert(key.len > 0);

        // Check existence first
        const obj_ptr = self.map.getPtr(key) orelse return null;

        // Check expiration before type checking
        if (self.expiration_map.get(key)) |expiration_time| {
            const timestamp = Io.Clock.real.now(self.io) catch unreachable;
            const now = timestamp.toMilliseconds();

            if (now > expiration_time) {
                _ = self.delete(key);
                return null;
            }
        }

        // Type check and return
        switch (obj_ptr.value) {
            .time_series => |ts_ptr| return ts_ptr,
            else => return error.WrongType,
        }
    }

    pub fn createList(self: *Store, key: []const u8) !*ZedisList {
        assert(key.len > 0);
        // Create list - error if key already exists
        const list_ptr = try self.allocator.create(ZedisList);
        list_ptr.* = ZedisList.init(self.allocator);
        const zedis_object: ZedisObject = .{ .value = .{ .list = list_ptr } };

        try self.putObject(key, zedis_object);

        return self.map.getPtr(key).?.value.list;
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
        if (self.map.getKey(key)) |existing_key| {
            // Use the key from the map (already owned) for expiration map
            try self.expiration_map.put(self.allocator, existing_key, time);
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

        // Use iterator to find the key at random_idx
        var it = self.map.iterator();
        var current_idx: usize = 0;
        while (it.next()) |entry| {
            if (current_idx == random_idx) {
                return entry.key_ptr.*;
            }
            current_idx += 1;
        }

        return null;
    }

    pub inline fn flush_db(self: *Store) void {
        var map_it = self.map.iterator();
        while (map_it.next()) |entry| {
            // Free the key
            if (entry.key_ptr.*.len > 0) self.allocator.free(entry.key_ptr.*);

            // Free the value
            switch (entry.value_ptr.*.value) {
                .string => |str| {
                    if (str.len > 0) self.allocator.free(str);
                },
                .int => {},
                .list => |list| {
                    list.deinit();
                    self.allocator.destroy(list);
                },
                .short_string => {},
                .time_series => |ts| {
                    ts.deinit();
                    self.allocator.destroy(ts);
                },
            }
        }

        // Clear the map to remove all keys
        self.map.clearRetainingCapacity();
    }

    /// Sample random keys and return the least recently used one (approximate LRU)
    /// If volatile_only is true, only samples keys with expiration set (volatile-lru policy)
    pub fn sampleLRUKey(self: *Store, sample_size: usize, volatile_only: bool) ?[]const u8 {
        // Check appropriate map based on policy
        const total_keys = if (volatile_only) self.expiration_map.count() else self.map.count();
        if (total_keys == 0) return null;

        var oldest_key: ?[]const u8 = null;

        // Use a simple PRNG for sampling
        var prng = std.Random.DefaultPrng.init(0);
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
                        oldest_key = key;
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
                        oldest_key = entry.key_ptr.*;
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
        const ts_ptr = try self.allocator.create(TimeSeries);
        ts_ptr.* = ts;
        try self.putObject(key, .{ .value = .{ .time_series = ts_ptr } });
    }

    /// Smart maintenance trigger with rate limiting
    /// Call this after operations that modify the map (delete, put)
    pub inline fn maybeMaintenance(self: *Store) void {
        const timestamp = Io.Clock.real.now(self.io) catch unreachable;
        const now = timestamp.toMilliseconds();

        // Rate limit: Don't check more than once per 50ms to avoid overhead
        if (now - self.last_maintenance_check < 50) return;
        self.last_maintenance_check = now;

        // Quick threshold checks
        const capacity = self.map.capacity();
        if (capacity == 0) return;

        const entry_count = self.map.count();
        const waste = capacity - entry_count;

        // Only run maintenance if waste is significant
        // Threshold 1: 50% waste (capacity is 2× entry_count)
        // Threshold 2: 25% of capacity deleted since last rehash
        if ((waste > capacity / 2) or (self.deletions_since_rehash > capacity / 4)) {
            self.maintenance();
        }
    }

    /// Maintenance function to prevent tombstone accumulation
    /// Called automatically by maybeMaintenance() when thresholds are met
    pub fn maintenance(self: *Store) void {
        const capacity = self.map.capacity();
        const entry_count = self.map.count();

        // If map is empty, nothing to do
        if (entry_count == 0 or capacity == 0) {
            self.deletions_since_rehash = 0;
            return;
        }

        // Estimate tombstone ratio
        // After many deletions, capacity stays the same but entry_count decreases
        // Rough heuristic: if capacity > 2 × entry_count, we likely have many tombstones
        const estimated_waste_ratio = @as(f64, @floatFromInt(capacity - entry_count)) /
            @as(f64, @floatFromInt(capacity));

        // Rehash if:
        // 1. Waste ratio > 50% (capacity is 2× entry_count or more)
        // 2. OR we've deleted > capacity/4 keys since last rehash
        const should_rehash = (estimated_waste_ratio > 0.5) or
            (self.deletions_since_rehash > capacity / 4);

        if (should_rehash) {
            // Create new map with appropriate capacity for current size
            var new_map = std.StringHashMapUnmanaged(ZedisObject){};
            new_map.ensureTotalCapacity(self.allocator, entry_count) catch return;

            // Copy all entries to new map
            var it = self.map.iterator();
            while (it.next()) |entry| {
                new_map.putAssumeCapacity(entry.key_ptr.*, entry.value_ptr.*);
            }

            // Deinit old map (this frees the internal storage but not our keys/values)
            self.map.deinit(self.allocator);

            // Swap to new map
            self.map = new_map;
            self.deletions_since_rehash = 0;
        }
    }
};
