const std = @import("std");
const ZedisList = @import("list.zig").ZedisList;
const ts_module = @import("time_series.zig");
const TimeSeries = ts_module.TimeSeries;
const Io = std.Io;
const Clock = @import("clock.zig");
const Config = @import("config.zig");
const string_match = @import("./util/string_match.zig").string_match;
const ScalableBloomFilter = @import("./bloom/bloom.zig").BloomFilter;

const assert = std.debug.assert;

// Optimal load factor
const optimal_max_load_percentage = 80;
const expired_eviction_scan_limit = 16;

const EntryMap = std.StringHashMapUnmanaged(*StoreEntry);

pub const ValueType = enum(u8) {
    string = 0,
    int,
    list,
    short_string,
    time_series,
    bloom_filter,

    pub fn toRdbOpcode(self: ValueType) u8 {
        return @intFromEnum(self);
    }

    pub fn fromOpCode(num: u8) ValueType {
        return @enumFromInt(num);
    }
};

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

pub const ZedisValue = union(ValueType) {
    string: []const u8,
    int: i64,
    list: *ZedisList,
    short_string: ShortString,
    time_series: *TimeSeries,
    bloom_filter: *ScalableBloomFilter,
};

pub const ZedisObject = struct {
    value: ZedisValue,
};

const StoreEntry = struct {
    key: []const u8,
    object: ZedisObject,
    expires_at: ?i64 = null,
    last_access: u64 = 0,
    prev_lru: ?*StoreEntry = null,
    next_lru: ?*StoreEntry = null,
    prev_volatile: ?*StoreEntry = null,
    next_volatile: ?*StoreEntry = null,
};

pub const StoreOptions = struct {
    initial_capacity: u32 = 100,
    eviction_policy: Config.EvictionPolicy = .allkeys_lru,
    maxmemory_samples: u32 = 5,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    map: EntryMap,

    io: Io,
    clock: *Clock,

    lru_clock: std.atomic.Value(u64),

    lru_head: ?*StoreEntry,
    lru_tail: ?*StoreEntry,
    volatile_lru_head: ?*StoreEntry,
    volatile_lru_tail: ?*StoreEntry,
    allkeys_sample_cursor: ?*StoreEntry,
    volatile_sample_cursor: ?*StoreEntry,

    deletions_since_rehash: usize,
    last_maintenance_check: i64,
    eviction_policy: Config.EvictionPolicy,
    maxmemory_samples: usize,

    inline fn maybeResize(self: *Store) !void {
        const capacity = self.map.capacity();
        if (capacity == 0) {
            try self.map.ensureTotalCapacity(self.allocator, 1);
            return;
        }

        const current_load = (self.map.count() * 100) / capacity;
        if (current_load > optimal_max_load_percentage) {
            const new_capacity = capacity * 2;
            try self.map.ensureTotalCapacity(self.allocator, new_capacity);
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: Io, clock: *Clock, options: StoreOptions) !Store {
        var map: EntryMap = .empty;
        try map.ensureTotalCapacity(allocator, options.initial_capacity);

        return .{
            .allocator = allocator,
            .map = map,
            .lru_clock = .init(0),
            .lru_head = null,
            .lru_tail = null,
            .volatile_lru_head = null,
            .volatile_lru_tail = null,
            .allkeys_sample_cursor = null,
            .volatile_sample_cursor = null,
            .deletions_since_rehash = 0,
            .last_maintenance_check = 0,
            .eviction_policy = options.eviction_policy,
            .maxmemory_samples = @max(@as(usize, @intCast(options.maxmemory_samples)), 1),
            .io = io,
            .clock = clock,
        };
    }

    pub fn deinit(self: *Store) void {
        var map_it = self.map.iterator();
        while (map_it.next()) |entry| {
            self.freeEntry(entry.value_ptr.*);
        }

        self.map.deinit(self.allocator);
        self.lru_head = null;
        self.lru_tail = null;
        self.volatile_lru_head = null;
        self.volatile_lru_tail = null;
        self.allkeys_sample_cursor = null;
        self.volatile_sample_cursor = null;
    }

    pub inline fn size(self: Store) u32 {
        return @intCast(self.map.count());
    }

    fn deleteMapEntry(self: *Store, map_entry: EntryMap.Entry) void {
        const entry = map_entry.value_ptr.*;
        self.map.removeByPtr(map_entry.key_ptr);
        self.freeEntry(entry);
        self.deletions_since_rehash += 1;
        self.maybeMaintenance();
    }

    fn nextAccessStamp(self: *Store) u64 {
        return self.lru_clock.fetchAdd(1, .monotonic) + 1;
    }

    inline fn usesGlobalLru(self: *const Store) bool {
        return self.eviction_policy == .allkeys_lru;
    }

    inline fn tracksVolatileEntries(self: *const Store) bool {
        return self.eviction_policy != .noeviction;
    }

    inline fn tracksAccessTime(self: *const Store) bool {
        return self.eviction_policy != .noeviction;
    }

    fn cloneOwnedObject(self: *Store, object: ZedisObject) !ZedisObject {
        var cloned = object;
        switch (object.value) {
            .string => |str| {
                const value_copy = try self.allocator.dupe(u8, str);
                cloned.value = .{ .string = value_copy };
            },
            .int => {},
            .list => {},
            .short_string => {},
            .time_series => {},
            .bloom_filter => {},
        }
        return cloned;
    }

    fn freeObjectValue(self: *Store, object: ZedisObject) void {
        switch (object.value) {
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
            .bloom_filter => |bf_ptr| {
                bf_ptr.deinit();
                self.allocator.destroy(bf_ptr);
            },
        }
    }

    fn detachLru(self: *Store, entry: *StoreEntry) void {
        const fallback = entry.prev_lru orelse entry.next_lru;

        if (entry.prev_lru) |prev| {
            prev.next_lru = entry.next_lru;
        } else if (self.lru_head == entry) {
            self.lru_head = entry.next_lru;
        }

        if (entry.next_lru) |next| {
            next.prev_lru = entry.prev_lru;
        } else if (self.lru_tail == entry) {
            self.lru_tail = entry.prev_lru;
        }

        entry.prev_lru = null;
        entry.next_lru = null;

        if (self.allkeys_sample_cursor == entry) {
            self.allkeys_sample_cursor = fallback;
        }
    }

    fn attachLruHead(self: *Store, entry: *StoreEntry) void {
        entry.prev_lru = null;
        entry.next_lru = self.lru_head;

        if (self.lru_head) |head| {
            head.prev_lru = entry;
        } else {
            self.lru_tail = entry;
        }

        self.lru_head = entry;
    }

    fn detachVolatile(self: *Store, entry: *StoreEntry) void {
        const fallback = entry.prev_volatile orelse entry.next_volatile;

        if (entry.prev_volatile) |prev| {
            prev.next_volatile = entry.next_volatile;
        } else if (self.volatile_lru_head == entry) {
            self.volatile_lru_head = entry.next_volatile;
        }

        if (entry.next_volatile) |next| {
            next.prev_volatile = entry.prev_volatile;
        } else if (self.volatile_lru_tail == entry) {
            self.volatile_lru_tail = entry.prev_volatile;
        }

        entry.prev_volatile = null;
        entry.next_volatile = null;

        if (self.volatile_sample_cursor == entry) {
            self.volatile_sample_cursor = fallback;
        }
    }

    fn attachVolatileHead(self: *Store, entry: *StoreEntry) void {
        entry.prev_volatile = null;
        entry.next_volatile = self.volatile_lru_head;

        if (self.volatile_lru_head) |head| {
            head.prev_volatile = entry;
        } else {
            self.volatile_lru_tail = entry;
        }

        self.volatile_lru_head = entry;
    }

    fn recordAccess(self: *Store, entry: *StoreEntry) void {
        if (!self.tracksAccessTime()) return;
        entry.last_access = self.nextAccessStamp();
    }

    fn touchEntry(self: *Store, entry: *StoreEntry) void {
        self.recordAccess(entry);
    }

    fn freeEntry(self: *Store, entry: *StoreEntry) void {
        self.detachLru(entry);
        self.detachVolatile(entry);
        self.freeObjectValue(entry.object);
        if (entry.key.len > 0) self.allocator.free(entry.key);
        self.allocator.destroy(entry);
    }

    fn resolveEntry(self: *Store, key: []const u8, touch: bool) ?*StoreEntry {
        const map_entry = self.map.getEntry(key) orelse return null;
        const entry = map_entry.value_ptr.*;

        if (entry.expires_at) |expiration_time| {
            const now = self.clock.now().toMilliseconds();
            if (now > expiration_time) {
                self.deleteMapEntry(map_entry);
                return null;
            }
        }

        if (touch) self.touchEntry(entry);
        return entry;
    }

    fn setString(self: *Store, key: []const u8, value: []const u8) !void {
        const zedis_value: ZedisValue = if (value.len <= 23)
            .{ .short_string = ShortString.fromSlice(value) }
        else
            .{ .string = value };
        try self.putObject(key, .{ .value = zedis_value });
    }

    pub fn setInt(self: *Store, key: []const u8, value: i64) !void {
        try self.putObject(key, .{ .value = .{ .int = value } });
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        try self.setString(key, value);
    }

    pub inline fn putObject(self: *Store, key: []const u8, object: ZedisObject) !void {
        assert(key.len > 0);

        if (self.map.get(key)) |entry| {
            if (std.meta.activeTag(entry.object.value) == .time_series) {
                return error.AlreadyExists;
            }

            // Mark the entry as recently used before allocating the replacement
            // value so LRU-driven allocators don't evict the key being updated.
            self.touchEntry(entry);

            const new_object = try self.cloneOwnedObject(object);
            errdefer self.freeObjectValue(new_object);

            self.freeObjectValue(entry.object);
            entry.object = new_object;
            return;
        }

        try self.maybeResize();

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        const new_object = try self.cloneOwnedObject(object);
        errdefer self.freeObjectValue(new_object);

        const entry = try self.allocator.create(StoreEntry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .key = owned_key,
            .object = new_object,
            .last_access = if (self.tracksAccessTime()) self.nextAccessStamp() else 0,
        };

        try self.map.put(self.allocator, entry.key, entry);
        if (self.usesGlobalLru()) {
            self.attachLruHead(entry);
        }
    }

    pub fn delete(self: *Store, key: []const u8) bool {
        assert(key.len > 0);

        const map_entry = self.map.getEntry(key) orelse return false;
        self.deleteMapEntry(map_entry);
        return true;
    }

    pub inline fn exists(self: *Store, key: []const u8) bool {
        assert(key.len > 0);
        return self.resolveEntry(key, false) != null;
    }

    pub inline fn getType(self: *Store, key: []const u8) ?ValueType {
        assert(key.len > 0);
        const entry = self.resolveEntry(key, false) orelse return null;
        return std.meta.activeTag(entry.object.value);
    }

    pub inline fn get(self: *Store, key: []const u8) ?*const ZedisObject {
        assert(key.len > 0);
        const entry = self.resolveEntry(key, true) orelse return null;
        return &entry.object;
    }

    pub fn keys(self: Store, allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const key = entry.value_ptr.*.key;
            if (pattern.len == 0 or string_match(pattern, key)) {
                try result.append(allocator, key);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getList(self: *Store, key: []const u8) !?*ZedisList {
        assert(key.len > 0);
        const entry = self.resolveEntry(key, true) orelse return null;

        switch (entry.object.value) {
            .list => |list_ptr| return list_ptr,
            else => return error.WrongType,
        }
    }

    pub fn getTimeSeries(self: *Store, key: []const u8) !?*TimeSeries {
        assert(key.len > 0);
        const entry = self.resolveEntry(key, true) orelse return null;

        switch (entry.object.value) {
            .time_series => |ts_ptr| return ts_ptr,
            else => return error.WrongType,
        }
    }

    pub fn createList(self: *Store, key: []const u8) !*ZedisList {
        assert(key.len > 0);
        const list_ptr = try self.allocator.create(ZedisList);
        errdefer self.allocator.destroy(list_ptr);

        list_ptr.* = ZedisList.init(self.allocator);
        try self.putObject(key, .{ .value = .{ .list = list_ptr } });
        return self.resolveEntry(key, true).?.object.value.list;
    }

    pub fn createBloomFilter(self: *Store, key: []const u8, bf: ScalableBloomFilter) !void {
        assert(key.len > 0);
        if (self.exists(key)) return error.AlreadyExists;

        const bf_ptr = try self.allocator.create(ScalableBloomFilter);
        errdefer self.allocator.destroy(bf_ptr);

        bf_ptr.* = bf;
        try self.putObject(key, .{ .value = .{ .bloom_filter = bf_ptr } });
    }

    pub fn getBloomFilter(self: *Store, key: []const u8) !?*ScalableBloomFilter {
        assert(key.len > 0);
        const entry = self.resolveEntry(key, true) orelse return null;

        switch (entry.object.value) {
            .bloom_filter => |bf_ptr| return bf_ptr,
            else => return error.WrongType,
        }
    }

    pub fn getSetList(self: *Store, key: []const u8) !*ZedisList {
        const list = try self.getList(key);
        if (list == null) return try self.createList(key);
        return list.?;
    }

    pub fn expire(self: *Store, key: []const u8, time: i64) !bool {
        assert(key.len > 0);
        assert(time > 0);

        const entry = self.map.get(key) orelse return false;
        entry.expires_at = time;
        self.touchEntry(entry);
        if (self.tracksVolatileEntries()) {
            if (entry.prev_volatile != null or entry.next_volatile != null or self.volatile_lru_head == entry) {
                self.detachVolatile(entry);
                self.attachVolatileHead(entry);
            } else {
                self.attachVolatileHead(entry);
            }
        }
        return true;
    }

    pub inline fn isExpired(self: Store, key: []const u8) bool {
        assert(key.len > 0);
        const entry = self.map.get(key) orelse return false;
        const expiration_time = entry.expires_at orelse return false;
        return self.clock.now().toMilliseconds() > expiration_time;
    }

    pub inline fn getTtl(self: Store, key: []const u8) ?i64 {
        assert(key.len > 0);
        const entry = self.map.get(key) orelse return null;
        return entry.expires_at;
    }

    pub inline fn persist(self: *Store, key: []const u8) bool {
        assert(key.len > 0);
        const entry = self.map.get(key) orelse return false;
        if (entry.expires_at == null) return false;

        entry.expires_at = null;
        if (self.tracksVolatileEntries()) {
            self.detachVolatile(entry);
        }
        self.touchEntry(entry);
        return true;
    }

    pub inline fn randomKey(self: *Store, random: std.Random) ?[]const u8 {
        const total_keys = self.map.count();
        if (total_keys == 0) return null;

        const random_idx = random.intRangeAtMost(usize, 0, total_keys - 1);

        var it = self.map.iterator();
        var current_idx: usize = 0;
        while (it.next()) |entry| {
            if (current_idx == random_idx) {
                return entry.value_ptr.*.key;
            }
            current_idx += 1;
        }

        return null;
    }

    pub inline fn flush_db(self: *Store) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.freeEntry(entry.value_ptr.*);
        }

        self.map.clearRetainingCapacity();
        self.lru_head = null;
        self.lru_tail = null;
        self.volatile_lru_head = null;
        self.volatile_lru_tail = null;
        self.allkeys_sample_cursor = null;
        self.volatile_sample_cursor = null;
        self.deletions_since_rehash = 0;
    }

    fn evictExpiredVolatile(self: *Store) bool {
        var scanned: usize = 0;
        var current = self.volatile_lru_tail;

        while (current) |entry| : (scanned += 1) {
            if (scanned >= expired_eviction_scan_limit) break;

            const prev = entry.prev_volatile;
            const expiration_time = entry.expires_at orelse {
                current = prev;
                continue;
            };

            if (self.clock.now().toMilliseconds() > expiration_time) {
                return self.delete(entry.key);
            }

            current = prev;
        }

        return false;
    }

    fn sampleGlobalVictim(self: *Store) ?*StoreEntry {
        const start = self.allkeys_sample_cursor orelse self.lru_tail orelse return null;

        var best = start;
        var current = start;
        var scanned: usize = 0;
        var next_cursor: ?*StoreEntry = null;

        while (true) {
            if (current.last_access < best.last_access) {
                best = current;
            }

            scanned += 1;
            next_cursor = current.prev_lru orelse self.lru_tail;

            if (scanned >= self.maxmemory_samples) break;
            if (next_cursor == null or next_cursor.? == start) break;

            current = next_cursor.?;
        }

        self.allkeys_sample_cursor = next_cursor;
        return best;
    }

    fn sampleVolatileVictim(self: *Store) ?*StoreEntry {
        const start = self.volatile_sample_cursor orelse self.volatile_lru_tail orelse return null;

        var best = start;
        var current = start;
        var scanned: usize = 0;
        var next_cursor: ?*StoreEntry = null;

        while (true) {
            if (current.last_access < best.last_access) {
                best = current;
            }

            scanned += 1;
            next_cursor = current.prev_volatile orelse self.volatile_lru_tail;

            if (scanned >= self.maxmemory_samples) break;
            if (next_cursor == null or next_cursor.? == start) break;

            current = next_cursor.?;
        }

        self.volatile_sample_cursor = next_cursor;
        return best;
    }

    pub fn evictOne(self: *Store, policy: Config.EvictionPolicy) bool {
        switch (policy) {
            .noeviction => return false,
            .allkeys_lru => {
                if (self.evictExpiredVolatile()) return true;
                const victim = self.sampleGlobalVictim() orelse return false;
                return self.delete(victim.key);
            },
            .volatile_lru => {
                if (self.evictExpiredVolatile()) return true;
                const victim = self.sampleVolatileVictim() orelse return false;
                return self.delete(victim.key);
            },
        }
    }

    pub fn renameKey(self: *Store, old_key: []const u8, new_key: []const u8) !bool {
        assert(old_key.len > 0);
        assert(new_key.len > 0);

        if (std.mem.eql(u8, old_key, new_key)) {
            return self.resolveEntry(old_key, false) != null;
        }

        const entry = self.resolveEntry(old_key, false) orelse return false;

        if (self.map.get(new_key)) |_| {
            _ = self.delete(new_key);
        }

        const new_owned_key = try self.allocator.dupe(u8, new_key);
        errdefer self.allocator.free(new_owned_key);

        const old_owned_key = entry.key;
        const removed = self.map.remove(old_key);
        assert(removed);

        entry.key = new_owned_key;
        self.map.put(self.allocator, entry.key, entry) catch |err| {
            entry.key = old_owned_key;
            self.map.put(self.allocator, old_owned_key, entry) catch unreachable;
            return err;
        };

        self.allocator.free(old_owned_key);
        self.touchEntry(entry);
        return true;
    }

    pub fn createTimeSeries(self: *Store, key: []const u8, ts: TimeSeries) !void {
        assert(key.len > 0);
        const ts_ptr = try self.allocator.create(TimeSeries);
        errdefer self.allocator.destroy(ts_ptr);

        ts_ptr.* = ts;
        try self.putObject(key, .{ .value = .{ .time_series = ts_ptr } });
    }

    pub inline fn maybeMaintenance(self: *Store) void {
        const now = self.clock.now().toMilliseconds();
        if (now - self.last_maintenance_check < 50) return;
        self.last_maintenance_check = now;

        const capacity = self.map.capacity();
        if (capacity == 0) return;

        const entry_count = self.map.count();
        const waste = capacity - entry_count;

        if ((waste > capacity / 2) or (self.deletions_since_rehash > capacity / 4)) {
            self.maintenance();
        }
    }

    pub fn maintenance(self: *Store) void {
        const capacity = self.map.capacity();
        const entry_count = self.map.count();

        if (entry_count == 0 or capacity == 0) {
            self.deletions_since_rehash = 0;
            return;
        }

        const estimated_waste_ratio = @as(f64, @floatFromInt(capacity - entry_count)) /
            @as(f64, @floatFromInt(capacity));

        const should_rehash = (estimated_waste_ratio > 0.5) or
            (self.deletions_since_rehash > capacity / 4);

        if (should_rehash) {
            var new_map: EntryMap = .empty;
            new_map.ensureTotalCapacity(self.allocator, entry_count) catch return;

            var it = self.map.iterator();
            while (it.next()) |entry| {
                new_map.putAssumeCapacity(entry.value_ptr.*.key, entry.value_ptr.*);
            }

            self.map.deinit(self.allocator);
            self.map = new_map;
            self.deletions_since_rehash = 0;
        }
    }
};
