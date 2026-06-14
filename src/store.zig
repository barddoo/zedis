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
const testing = std.testing;

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

pub const ShortString = @import("types.zig").ShortString;
pub const PrimitiveValue = @import("types.zig").PrimitiveValue;

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

test "Store init and deinit" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.size());
}

test "Store set and get" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result = store.get("key1");
    try testing.expect(result != null);
    try testing.expectEqualStrings("hello", result.?.value.short_string.asSlice());
}

test "Store setInt and get" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.setInt("counter", 42);
    try testing.expectEqual(@as(u32, 1), store.size());

    const result = store.get("counter");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 42), result.?.value.int);
}

test "Store setObject with ZedisObject" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const obj = ZedisObject{ .value = .{ .string = try testing.testing.allocator.dupe(u8, "test") } };
    defer testing.allocator.free(obj.value.string);
    try store.putObject("key1", obj);

    const result = store.get("key1");
    try testing.expect(result != null);
    try testing.expectEqualStrings("test", result.?.value.string);
}

test "Store delete existing key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "value1");
    try testing.expectEqual(@as(u32, 1), store.size());
    try testing.expect(store.exists("key1"));

    const deleted = store.delete("key1");
    try testing.expect(deleted);
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(!store.exists("key1"));
}

test "Store delete non-existing key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const deleted = store.delete("nonexistent");
    try testing.expect(!deleted);
}

test "Store exists" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expect(!store.exists("key1"));

    try store.set("key1", "value1");
    try testing.expect(store.exists("key1"));

    _ = store.delete("key1");
    try testing.expect(!store.exists("key1"));
}

test "Store getType" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expect(store.getType("nonexistent") == null);

    try store.set("str_key", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("str_key").?);

    try store.setInt("int_key", 42);
    try testing.expectEqual(ValueType.int, store.getType("int_key").?);
}

test "Store overwrite existing key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "original");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result1 = store.get("key1");
    try testing.expect(result1 != null);
    try testing.expectEqualStrings("original", result1.?.value.short_string.asSlice());

    try store.set("key1", "updated");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result2 = store.get("key1");
    try testing.expect(result2 != null);
    try testing.expectEqualStrings("updated", result2.?.value.short_string.asSlice());
}

test "Store overwrite string with integer" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);

    try store.setInt("key1", 123);
    try testing.expectEqual(ValueType.int, store.getType("key1").?);
    try testing.expectEqual(@as(i64, 123), store.get("key1").?.value.int);
}

test "Store overwrite integer with string" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.setInt("key1", 456);
    try testing.expectEqual(ValueType.int, store.getType("key1").?);

    try store.set("key1", "world");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);
    try testing.expectEqualStrings("world", store.get("key1").?.value.short_string.asSlice());
}

test "Store expire functionality" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "value1");
    try testing.expect(!store.isExpired("key1"));

    // Set expiration to far future
    const now = Io.Clock.real.now(testing.io);
    const future_time = now.toMilliseconds() + 1000000;
    const success = try store.expire("key1", future_time);
    try testing.expect(success);
    try testing.expect(!store.isExpired("key1"));
    try testing.expect(store.get("key1") != null);
    try testing.expectEqual(future_time, store.getTtl("key1").?);

    // Set expiration to past
    const past_time: i64 = 12345;
    _ = try store.expire("key1", past_time);
    try testing.expect(store.isExpired("key1"));
    try testing.expect(store.get("key1") == null); // Should be deleted on get
}

test "Store expire non-existing key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const success = try store.expire("nonexistent", 12345);
    try testing.expect(!success);
}

test "Store delete removes from expiration map" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "value1");
    _ = try store.expire("key1", 12345);

    const deleted = store.delete("key1");
    try testing.expect(deleted);
    try testing.expect(!store.isExpired("key1"));
}

test "Store multiple keys with different types" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.setInt("int1", 123);
    try store.setInt("int2", -456);

    try testing.expectEqual(@as(u32, 4), store.size());

    try testing.expectEqualStrings("hello", store.get("str1").?.value.short_string.asSlice());
    try testing.expectEqualStrings("world", store.get("str2").?.value.short_string.asSlice());
    try testing.expectEqual(@as(i64, 123), store.get("int1").?.value.int);
    try testing.expectEqual(@as(i64, -456), store.get("int2").?.value.int);
}

test "Store empty string values" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("empty", "");

    const result = store.get("empty");
    try testing.expect(result != null);
    try testing.expectEqualStrings("", result.?.value.short_string.asSlice());
}

test "Store zero integer values" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.setInt("zero", 0);

    const result = store.get("zero");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 0), result.?.value.int);
}

test "Store createList and getList" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expect(try store.getList("mylist") == null);

    const list = try store.createList("mylist");
    try testing.expectEqual(@as(usize, 0), list.len());

    const retrieved_list = try store.getList("mylist");
    try testing.expect(retrieved_list != null);
    try testing.expectEqual(@as(usize, 0), retrieved_list.?.len());
}

test "Store list append and insert operations" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.createList("test_append_insert");

    try testing.expectEqual(@as(usize, 0), list.len());

    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "first") });
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("first", list.getByIndex(0).?.string);

    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "second") });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("second", list.getByIndex(1).?.string);

    try list.prepend(.{ .string = try testing.testing.allocator.dupe(u8, "zero") });
    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expectEqualStrings("zero", list.getByIndex(0).?.string);
    try testing.expectEqualStrings("first", list.getByIndex(1).?.string);
    try testing.expectEqualStrings("second", list.getByIndex(2).?.string);
}

test "Store list with mixed value types" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.createList("test_mixed_values");

    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "hello") });
    try list.append(.{ .int = 42 });
    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "world") });

    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expectEqualStrings("hello", list.getByIndex(0).?.string);
    try testing.expectEqual(@as(i64, 42), list.getByIndex(1).?.int);
    try testing.expectEqualStrings("world", list.getByIndex(2).?.string);
}

test "Store getList with wrong type" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("notalist", "hello");

    const list = store.getList("notalist");
    try testing.expect(list == error.WrongType);
}

test "Store list type checking" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    _ = try store.createList("mylist");
    try testing.expectEqual(ValueType.list, store.getType("mylist").?);
}

test "Store overwrite string with list" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);

    _ = try store.createList("key1");
    try testing.expectEqual(ValueType.list, store.getType("key1").?);

    const list = try store.getList("key1");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 0), list.?.len());
}

test "Store overwrite list with string" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.createList("key1");
    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "item") });
    try testing.expectEqual(ValueType.list, store.getType("key1").?);

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.getType("key1").?);
    try testing.expectEqualStrings("hello", store.get("key1").?.value.short_string.asSlice());

    const retrieved_list = store.getList("key1");
    try testing.expect(retrieved_list == error.WrongType);
}

test "Store delete list key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.createList("mylist");
    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "item2") });

    try testing.expect(store.exists("mylist"));
    try testing.expectEqual(@as(u32, 1), store.size());

    const deleted = store.delete("mylist");
    try testing.expect(deleted);
    try testing.expect(!store.exists("mylist"));
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(try store.getList("mylist") == null);
}

test "Store empty list operations" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.createList("test_empty_ops");
    try testing.expectEqual(@as(usize, 0), list.len());

    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "") });
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("", list.getByIndex(0).?.string);

    try list.append(.{ .int = 0 });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqual(@as(i64, 0), list.getByIndex(1).?.int);
}

test "Store flush_db removes all keys" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // Add various types of keys
    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.setInt("int1", 42);
    try store.setInt("int2", -100);

    const list = try store.createList("mylist");
    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try testing.testing.allocator.dupe(u8, "item2") });

    // Verify all keys exist
    try testing.expectEqual(@as(u32, 5), store.size());
    try testing.expect(store.exists("str1"));
    try testing.expect(store.exists("str2"));
    try testing.expect(store.exists("int1"));
    try testing.expect(store.exists("int2"));
    try testing.expect(store.exists("mylist"));

    // Flush the database
    store.flush_db();

    // Verify all keys are removed
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(!store.exists("str1"));
    try testing.expect(!store.exists("str2"));
    try testing.expect(!store.exists("int1"));
    try testing.expect(!store.exists("int2"));
    try testing.expect(!store.exists("mylist"));

    // Verify getting keys returns null
    try testing.expect(store.get("str1") == null);
    try testing.expect(store.get("int1") == null);
    try testing.expect(try store.getList("mylist") == null);
}

test "Store flush_db on empty store" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expectEqual(@as(u32, 0), store.size());

    // Flush empty store should not crash
    store.flush_db();

    try testing.expectEqual(@as(u32, 0), store.size());
}

test "Store flush_db allows reuse after flush" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // Add keys
    try store.set("key1", "value1");
    try store.setInt("key2", 123);
    try testing.expectEqual(@as(u32, 2), store.size());

    // Flush
    store.flush_db();
    try testing.expectEqual(@as(u32, 0), store.size());

    // Add new keys after flush
    try store.set("key3", "value3");
    try store.setInt("key4", 456);
    try testing.expectEqual(@as(u32, 2), store.size());

    // Verify new keys work correctly
    try testing.expectEqualStrings("value3", store.get("key3").?.value.short_string.asSlice());
    try testing.expectEqual(@as(i64, 456), store.get("key4").?.value.int);

    // Verify old keys don't exist
    try testing.expect(store.get("key1") == null);
    try testing.expect(store.get("key2") == null);
}

test "Store maintenance() rehashes and reduces capacity" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add many keys to grow the capacity
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity_before = store.map.capacity();
    const size_before = store.map.count();
    try testing.expect(capacity_before > 0);
    try testing.expectEqual(@as(usize, 1000), size_before);

    // Delete half the keys to create tombstones
    i = 0;
    while (i < 500) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        const deleted = store.delete(key);
        try testing.expect(deleted);
    }

    const size_after_delete = store.map.count();
    try testing.expectEqual(@as(usize, 500), size_after_delete);

    // Deletes may trigger automatic maintenance, but capacity should never grow here.
    try testing.expect(store.map.capacity() <= capacity_before);

    // Run maintenance to clean up tombstones
    store.maintenance();

    const capacity_after = store.map.capacity();
    const size_after = store.map.count();

    // Size should remain the same
    try testing.expectEqual(@as(usize, 500), size_after);

    // Capacity should be reduced or at least not larger
    try testing.expect(capacity_after <= capacity_before);

    // Verify remaining keys are still accessible
    i = 500;
    while (i < 1000) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        const result = store.get(key);
        try testing.expect(result != null);
        try testing.expectEqualStrings("value", result.?.value.short_string.asSlice());
    }
}

test "Store maintenance() resets deletion counter" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add and delete keys to increment deletion counter
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
        _ = store.delete(key);
    }

    try testing.expect(store.deletions_since_rehash > 0);

    // Run maintenance
    store.maintenance();

    // Deletion counter should be reset
    try testing.expectEqual(@as(usize, 0), store.deletions_since_rehash);
}

test "Store maybeMaintenance() respects rate limiting" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add enough keys to trigger capacity growth
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    // Delete many keys to exceed threshold
    i = 0;
    while (i < 700) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    const capacity_before = store.map.capacity();

    // Reset last_maintenance_check to ensure our explicit call isn't rate-limited
    // (delete() calls maybeMaintenance() automatically, which may have updated it recently)
    store.last_maintenance_check = 0;
    const last_check_before = store.last_maintenance_check;

    // Call maybeMaintenance multiple times in quick succession
    store.maybeMaintenance();
    const capacity_after_first = store.map.capacity();
    const last_check_after_first = store.last_maintenance_check;

    // First call should trigger maintenance
    try testing.expect(capacity_after_first <= capacity_before);
    try testing.expect(last_check_after_first > last_check_before);

    // Immediately call again (within 50ms)
    store.maybeMaintenance();
    const capacity_after_second = store.map.capacity();
    const last_check_after_second = store.last_maintenance_check;

    // Second call should be rate-limited (no maintenance)
    try testing.expectEqual(capacity_after_first, capacity_after_second);
    try testing.expectEqual(last_check_after_first, last_check_after_second);
}

test "Store maybeMaintenance() triggers on 50% waste threshold" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add many keys
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity_before = store.map.capacity();

    // Delete more than 50% of capacity to trigger waste threshold
    // (capacity - count) > capacity / 2
    const target_deletions = (capacity_before / 2) + 10;
    i = 0;
    while (i < target_deletions) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    // Reset last_maintenance_check to avoid rate limiting
    store.last_maintenance_check = 0;

    // This should trigger maintenance due to waste threshold
    store.maybeMaintenance();

    // Deletion counter should be reset after maintenance
    try testing.expectEqual(@as(usize, 0), store.deletions_since_rehash);
}

test "Store maybeMaintenance() triggers on 25% deletions threshold" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add keys to establish capacity
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity = store.map.capacity();
    const threshold = capacity / 4;

    // Block the implicit maintenance calls inside delete() so this test can
    // deterministically verify the explicit maybeMaintenance() invocation.
    store.last_maintenance_check = store.clock.now().toMilliseconds() + 60_000;

    // Delete exactly threshold + 1 keys to trigger maintenance
    i = 0;
    while (i < threshold + 1) : (i += 1) {
        const key = try std.fmt.allocPrint(testing.allocator, "key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    try testing.expectEqual(threshold + 1, store.deletions_since_rehash);

    // Reset last_maintenance_check to avoid rate limiting
    store.last_maintenance_check = 0;

    // This should trigger maintenance due to deletion threshold
    store.maybeMaintenance();

    // Deletion counter should be reset after maintenance
    try testing.expectEqual(@as(usize, 0), store.deletions_since_rehash);
}

test "Store deletion tracking increments counter" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Initially, deletion counter should be 0
    try testing.expectEqual(@as(usize, 0), store.deletions_since_rehash);

    // Add and delete some keys
    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("key3", "value3");

    // Keep delete() from auto-triggering maintenance so we can verify the
    // raw deletion counter behavior directly.
    store.last_maintenance_check = store.clock.now().toMilliseconds() + 60_000;

    _ = store.delete("key1");
    try testing.expect(store.deletions_since_rehash >= 1);

    _ = store.delete("key2");
    try testing.expect(store.deletions_since_rehash >= 2);

    _ = store.delete("key3");
    try testing.expect(store.deletions_since_rehash >= 3);

    // Deleting non-existent key should not increment
    const before_failed_delete = store.deletions_since_rehash;
    _ = store.delete("nonexistent");
    try testing.expectEqual(before_failed_delete, store.deletions_since_rehash);
}

test "Store evictOne allkeys_lru evicts least recently used key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{
        .initial_capacity = 16,
        .eviction_policy = .allkeys_lru,
        .maxmemory_samples = 5,
    });
    defer store.deinit();

    try store.set("key1", "value1");
    try store.set("key2", "value2");
    try store.set("key3", "value3");

    _ = store.get("key1");

    try testing.expect(store.evictOne(.allkeys_lru));
    try testing.expect(store.get("key2") == null);
    try testing.expect(store.get("key1") != null);
    try testing.expect(store.get("key3") != null);
}

test "Store evictOne volatile_lru only evicts volatile keys" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{
        .initial_capacity = 16,
        .eviction_policy = .volatile_lru,
        .maxmemory_samples = 5,
    });
    defer store.deinit();

    try store.set("persistent", "value");
    try store.set("ttl1", "value1");
    try store.set("ttl2", "value2");

    const now = Io.Clock.real.now(testing.io).toMilliseconds();
    _ = try store.expire("ttl1", now + 10_000);
    _ = try store.expire("ttl2", now + 10_000);

    _ = store.get("ttl1");

    try testing.expect(store.evictOne(.volatile_lru));
    try testing.expect(store.get("ttl2") == null);
    try testing.expect(store.get("ttl1") != null);
    try testing.expect(store.get("persistent") != null);
}

test "Store evictOne prefers expired ttl entries before LRU tail" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{
        .initial_capacity = 16,
        .eviction_policy = .allkeys_lru,
        .maxmemory_samples = 5,
    });
    defer store.deinit();

    try store.set("fresh1", "value1");
    try store.set("expired", "value2");
    try store.set("fresh2", "value3");

    _ = try store.expire("expired", 1);
    _ = store.get("fresh2");

    try testing.expect(store.evictOne(.allkeys_lru));
    try testing.expect(store.get("expired") == null);
    try testing.expect(store.get("fresh1") != null);
    try testing.expect(store.get("fresh2") != null);
}
