const std = @import("std");
const ZedisList = @import("list.zig").ZedisList;
const ts_module = @import("time_series.zig");
const TimeSeries = ts_module.TimeSeries;
const Io = std.Io;
const Clock = @import("clock.zig");
const Config = @import("config.zig");
const string_match = @import("./util/string_match.zig").string_match;
const ScalableBloomFilter = @import("./bloom/bloom.zig").BloomFilter;
const SearchIndex = @import("./search/index.zig").SearchIndex;
pub const ShortString = @import("types.zig").ShortString;
pub const PrimitiveValue = @import("types.zig").PrimitiveValue;

const assert = std.debug.assert;

// Optimal load factor
const optimal_max_load_percentage = 80;
const expired_eviction_scan_limit = 16;

// Keys up to this many bytes are stored inline in the entry (no heap allocation).
const inline_key_max = 23;

const testing = std.testing;

pub const ValueType = enum(u8) {
    string = 0,
    int,
    list,
    short_string,
    time_series,
    bloom_filter,
    search_index,

    pub fn to_rdb_opcode(self: ValueType) u8 {
        return @backingInt(self);
    }

    pub fn from_op_code(num: u8) ValueType {
        return @fromBackingInt(@intCast(num));
    }
};

pub const ZedisValue = union(ValueType) {
    string: []const u8,
    int: i64,
    list: *ZedisList,
    short_string: ShortString,
    time_series: *TimeSeries,
    bloom_filter: *ScalableBloomFilter,
    search_index: *SearchIndex,
};

pub const ZedisObject = struct {
    value: ZedisValue,
};

// Open-addressing hash table slot: stored hash (fast probing) + entry index.
const empty_slot: u32 = std.math.maxInt(u32);
const tomb_slot: u32 = std.math.maxInt(u32) - 1;
const no_entry: u32 = std.math.maxInt(u32);

const Slot = struct {
    hash: u32,
    idx: u32,
};

const StoreEntry = struct {
    key: []const u8,
    inline_key_data: [inline_key_max]u8,
    object: ZedisObject,
    expires_at: ?i64 = null,
    last_access: u64 = 0,
    prev_lru: ?*StoreEntry = null,
    next_lru: ?*StoreEntry = null,
    prev_volatile: ?*StoreEntry = null,
    next_volatile: ?*StoreEntry = null,
    next_free: u32 = no_entry,
};

pub const StoreOptions = struct {
    initial_capacity: u32 = 100,
    eviction_policy: Config.EvictionPolicy = .allkeys_lru,
    maxmemory_samples: u32 = 5,
};

pub const EntryView = struct {
    key: []const u8,
    object: *const ZedisObject,
    expires_at: ?i64,
};

pub const Iterator = struct {
    store: *const Store,
    slot_index: usize,

    pub fn next(self: *Iterator) ?EntryView {
        while (self.slot_index < self.store.slots.len) {
            const s = self.store.slots[self.slot_index];
            self.slot_index += 1;
            if (s.idx == empty_slot or s.idx == tomb_slot) continue;
            const entry = self.store.entries[s.idx];
            return .{
                .key = entry.key,
                .object = &entry.object,
                .expires_at = entry.expires_at,
            };
        }
        return null;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    entries: []*StoreEntry,
    // Allocated length of `entries.ptr`; grown geometrically so inserts stay amortized O(1).
    entries_capacity: usize,
    count: usize,
    free_head: u32,

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

    inline fn keyHash(key: []const u8) u32 {
        return @truncate(std.hash.Wyhash.hash(0, key));
    }

    fn findSlot(self: *const Store, h32: u32, key: []const u8) ?usize {
        if (self.slots.len == 0) return null;
        const mask = self.slots.len - 1;
        var i: usize = @as(usize, h32) & mask;
        var remaining: usize = self.slots.len;
        while (remaining > 0) : (remaining -= 1) {
            const s = self.slots[i];
            if (s.idx == empty_slot) return null;
            if (s.idx != tomb_slot and s.hash == h32) {
                const entry = self.entries[s.idx];
                if (std.mem.eql(u8, entry.key, key)) return i;
            }
            i = (i + 1) & mask;
        }
        return null;
    }

    fn findInsertSlot(self: *const Store, h32: u32) usize {
        const mask = self.slots.len - 1;
        var i: usize = @as(usize, h32) & mask;
        while (self.slots[i].idx != empty_slot and self.slots[i].idx != tomb_slot) {
            i = (i + 1) & mask;
        }
        return i;
    }

    fn rebuildSlots(self: *Store, min_capacity: usize) !void {
        var cap: usize = 16;
        while (cap < min_capacity) cap *= 2;
        const new_slots = try self.allocator.alloc(Slot, cap);
        for (new_slots) |*s| s.* = .{ .hash = 0, .idx = empty_slot };
        if (self.slots.len > 0) {
            const mask = cap - 1;
            for (self.slots) |s| {
                if (s.idx == empty_slot or s.idx == tomb_slot) continue;
                var i: usize = @as(usize, s.hash) & mask;
                while (new_slots[i].idx != empty_slot and new_slots[i].idx != tomb_slot) i = (i + 1) & mask;
                new_slots[i] = s;
            }
            self.allocator.free(self.slots);
        }
        self.slots = new_slots;
    }

    fn allocEntry(self: *Store) !struct { idx: u32, entry: *StoreEntry } {
        if (self.free_head != no_entry) {
            const idx = self.free_head;
            const entry = self.entries[idx];
            self.free_head = entry.next_free;
            return .{ .idx = idx, .entry = entry };
        }
        const entry = try self.allocator.create(StoreEntry);
        errdefer self.allocator.destroy(entry);
        const new_len = self.entries.len + 1;
        if (new_len > self.entries_capacity) {
            const new_capacity = @max(16, self.entries_capacity * 2);
            const new_entries = try self.allocator.alloc(*StoreEntry, new_capacity);
            @memcpy(new_entries[0..self.entries.len], self.entries);
            self.free_entries_array();
            self.entries = new_entries[0..self.entries.len];
            self.entries_capacity = new_capacity;
        }
        self.entries.len = new_len;
        self.entries[new_len - 1] = entry;
        return .{ .idx = @intCast(new_len - 1), .entry = entry };
    }

    fn free_entries_array(self: *Store) void {
        if (self.entries_capacity > 0) self.allocator.free(self.entries.ptr[0..self.entries_capacity]);
        self.entries = &.{};
        self.entries_capacity = 0;
    }

    fn setEntryKey(self: *Store, entry: *StoreEntry, key: []const u8) !void {
        if (key.len <= inline_key_max) {
            @memcpy(entry.inline_key_data[0..key.len], key);
            entry.key = entry.inline_key_data[0..key.len];
        } else {
            entry.key = try self.allocator.dupe(u8, key);
        }
    }

    inline fn maybe_resize(self: *Store) !void {
        if (self.slots.len == 0) {
            try self.rebuildSlots(16);
            return;
        }
        if ((self.count + 1) * 100 >= self.slots.len * optimal_max_load_percentage) {
            try self.rebuildSlots(self.slots.len * 2);
        }
    }

    pub fn init(allocator: std.mem.Allocator, io: Io, clock: *Clock, options: StoreOptions) !Store {
        var store = Store{
            .allocator = allocator,
            .slots = &.{},
            .entries = &.{},
            .entries_capacity = 0,
            .count = 0,
            .free_head = no_entry,
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
        try store.rebuildSlots(options.initial_capacity);
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.slots) |s| {
            if (s.idx == empty_slot or s.idx == tomb_slot) continue;
            self.free_entry_contents(self.entries[s.idx]);
        }
        for (self.entries) |entry| {
            self.allocator.destroy(entry);
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.free_entries_array();
        self.slots = &.{};
        self.lru_head = null;
        self.lru_tail = null;
        self.volatile_lru_head = null;
        self.volatile_lru_tail = null;
        self.allkeys_sample_cursor = null;
        self.volatile_sample_cursor = null;
    }

    pub fn iterator(self: *const Store) Iterator {
        return .{ .store = self, .slot_index = 0 };
    }

    pub inline fn size(self: Store) u32 {
        return @intCast(self.count);
    }

    pub inline fn capacity(self: *const Store) usize {
        return self.slots.len;
    }

    fn delete_at_slot(self: *Store, slot: usize) void {
        const idx = self.slots[slot].idx;
        const entry = self.entries[idx];
        self.slots[slot] = .{ .hash = 0, .idx = tomb_slot };
        self.count -= 1;
        self.free_entry_contents(entry);
        entry.next_free = self.free_head;
        self.free_head = idx;
        self.deletions_since_rehash += 1;
        self.maybe_maintenance();
    }

    fn next_access_stamp(self: *Store) u64 {
        return self.lru_clock.fetchAdd(1, .monotonic) + 1;
    }

    inline fn uses_global_lru(self: *const Store) bool {
        return self.eviction_policy == .allkeys_lru;
    }

    inline fn tracks_volatile_entries(self: *const Store) bool {
        return self.eviction_policy != .noeviction;
    }

    inline fn tracks_access_time(self: *const Store) bool {
        return self.eviction_policy != .noeviction;
    }

    fn clone_owned_object(self: *Store, object: ZedisObject) !ZedisObject {
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
            .search_index => {},
        }
        return cloned;
    }

    fn free_object_value(self: *Store, object: ZedisObject) void {
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
            .search_index => |si_ptr| {
                si_ptr.deinit();
                self.allocator.destroy(si_ptr);
            },
        }
    }

    fn detach_lru(self: *Store, entry: *StoreEntry) void {
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

    fn attach_lru_head(self: *Store, entry: *StoreEntry) void {
        entry.prev_lru = null;
        entry.next_lru = self.lru_head;

        if (self.lru_head) |head| {
            head.prev_lru = entry;
        } else {
            self.lru_tail = entry;
        }

        self.lru_head = entry;
    }

    fn detach_volatile(self: *Store, entry: *StoreEntry) void {
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

    fn attach_volatile_head(self: *Store, entry: *StoreEntry) void {
        entry.prev_volatile = null;
        entry.next_volatile = self.volatile_lru_head;

        if (self.volatile_lru_head) |head| {
            head.prev_volatile = entry;
        } else {
            self.volatile_lru_tail = entry;
        }

        self.volatile_lru_head = entry;
    }

    fn record_access(self: *Store, entry: *StoreEntry) void {
        if (!self.tracks_access_time()) return;
        entry.last_access = self.next_access_stamp();
    }

    fn touch_entry(self: *Store, entry: *StoreEntry) void {
        self.record_access(entry);
    }

    fn free_entry_contents(self: *Store, entry: *StoreEntry) void {
        self.detach_lru(entry);
        self.detach_volatile(entry);
        self.free_object_value(entry.object);
        if (entry.key.len > inline_key_max) self.allocator.free(entry.key);
    }

    fn resolve_entry(self: *Store, key: []const u8, touch: bool) ?*StoreEntry {
        const slot = self.findSlot(keyHash(key), key) orelse return null;
        const entry = self.entries[self.slots[slot].idx];

        if (entry.expires_at) |expiration_time| {
            const now = self.clock.now().toMilliseconds();
            if (now > expiration_time) {
                self.delete_at_slot(slot);
                return null;
            }
        }

        if (touch) self.touch_entry(entry);
        return entry;
    }

    fn set_string(self: *Store, key: []const u8, value: []const u8) !void {
        const zedis_value: ZedisValue = if (value.len <= 23)
            .{ .short_string = ShortString.from_slice(value) }
        else
            .{ .string = value };
        try self.put_object(key, .{ .value = zedis_value });
    }

    pub fn set_int(self: *Store, key: []const u8, value: i64) !void {
        try self.put_object(key, .{ .value = .{ .int = value } });
    }

    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        try self.set_string(key, value);
    }

    pub inline fn put_object(self: *Store, key: []const u8, object: ZedisObject) !void {
        assert(key.len > 0);

        const h32 = keyHash(key);
        if (self.findSlot(h32, key)) |slot| {
            const entry = self.entries[self.slots[slot].idx];
            if (std.meta.activeTag(entry.object.value) == .time_series) {
                return error.AlreadyExists;
            }

            // Mark the entry as recently used before allocating the replacement
            // value so LRU-driven allocators don't evict the key being updated.
            self.touch_entry(entry);

            const new_object = try self.clone_owned_object(object);
            errdefer self.free_object_value(new_object);

            self.free_object_value(entry.object);
            entry.object = new_object;
            return;
        }

        try self.maybe_resize();

        const new_object = try self.clone_owned_object(object);
        errdefer self.free_object_value(new_object);

        const alloc = try self.allocEntry();
        const entry = alloc.entry;
        const idx = alloc.idx;

        entry.* = .{
            .key = undefined,
            .inline_key_data = undefined,
            .object = new_object,
            .last_access = if (self.tracks_access_time()) self.next_access_stamp() else 0,
        };

        try self.setEntryKey(entry, key);

        const slot = self.findInsertSlot(h32);
        self.slots[slot] = .{ .hash = h32, .idx = idx };
        self.count += 1;
        if (self.uses_global_lru()) {
            self.attach_lru_head(entry);
        }
    }

    pub fn delete(self: *Store, key: []const u8) bool {
        assert(key.len > 0);

        const slot = self.findSlot(keyHash(key), key) orelse return false;
        self.delete_at_slot(slot);
        return true;
    }

    pub inline fn exists(self: *Store, key: []const u8) bool {
        assert(key.len > 0);
        return self.resolve_entry(key, false) != null;
    }

    pub inline fn get_type(self: *Store, key: []const u8) ?ValueType {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, false) orelse return null;
        return std.meta.activeTag(entry.object.value);
    }

    pub inline fn get(self: *Store, key: []const u8) ?*const ZedisObject {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;
        return &entry.object;
    }

    pub fn keys(self: Store, allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;

        for (self.slots) |s| {
            if (s.idx == empty_slot or s.idx == tomb_slot) continue;
            const key = self.entries[s.idx].key;
            if (pattern.len == 0 or string_match(pattern, key)) {
                try result.append(allocator, key);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn get_list(self: *Store, key: []const u8) !?*ZedisList {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;

        switch (entry.object.value) {
            .list => |list_ptr| return list_ptr,
            else => return error.WrongType,
        }
    }

    pub fn get_time_series(self: *Store, key: []const u8) !?*TimeSeries {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;

        switch (entry.object.value) {
            .time_series => |ts_ptr| return ts_ptr,
            else => return error.WrongType,
        }
    }

    pub fn create_list(self: *Store, key: []const u8) !*ZedisList {
        assert(key.len > 0);
        const list_ptr = try self.allocator.create(ZedisList);
        errdefer self.allocator.destroy(list_ptr);

        list_ptr.* = ZedisList.init(self.allocator);
        try self.put_object(key, .{ .value = .{ .list = list_ptr } });
        return self.resolve_entry(key, true).?.object.value.list;
    }

    pub fn create_bloom_filter(self: *Store, key: []const u8, bf: ScalableBloomFilter) !void {
        assert(key.len > 0);
        if (self.exists(key)) return error.AlreadyExists;

        const bf_ptr = try self.allocator.create(ScalableBloomFilter);
        errdefer self.allocator.destroy(bf_ptr);

        bf_ptr.* = bf;
        try self.put_object(key, .{ .value = .{ .bloom_filter = bf_ptr } });
    }

    pub fn get_bloom_filter(self: *Store, key: []const u8) !?*ScalableBloomFilter {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;

        switch (entry.object.value) {
            .bloom_filter => |bf_ptr| return bf_ptr,
            else => return error.WrongType,
        }
    }

    pub fn create_search_index(self: *Store, key: []const u8, si: SearchIndex) !void {
        assert(key.len > 0);
        if (self.exists(key)) return error.AlreadyExists;

        const si_ptr = try self.allocator.create(SearchIndex);
        errdefer self.allocator.destroy(si_ptr);

        si_ptr.* = si;
        try self.put_object(key, .{ .value = .{ .search_index = si_ptr } });
    }

    pub fn get_search_index(self: *Store, key: []const u8) !?*SearchIndex {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;

        switch (entry.object.value) {
            .search_index => |si_ptr| return si_ptr,
            else => return error.WrongType,
        }
    }

    pub fn get_set_list(self: *Store, key: []const u8) !*ZedisList {
        const list = try self.get_list(key);
        if (list == null) return try self.create_list(key);
        return list.?;
    }

    pub fn expire(self: *Store, key: []const u8, time: i64) !bool {
        assert(key.len > 0);
        assert(time > 0);

        const slot = self.findSlot(keyHash(key), key) orelse return false;
        const entry = self.entries[self.slots[slot].idx];
        entry.expires_at = time;
        self.touch_entry(entry);
        if (self.tracks_volatile_entries()) {
            if (entry.prev_volatile != null or entry.next_volatile != null or self.volatile_lru_head == entry) {
                self.detach_volatile(entry);
                self.attach_volatile_head(entry);
            } else {
                self.attach_volatile_head(entry);
            }
        }
        return true;
    }

    pub inline fn is_expired(self: Store, key: []const u8) bool {
        assert(key.len > 0);
        const slot = self.findSlot(keyHash(key), key) orelse return false;
        const entry = self.entries[self.slots[slot].idx];
        const expiration_time = entry.expires_at orelse return false;
        return self.clock.now().toMilliseconds() > expiration_time;
    }

    pub inline fn get_ttl(self: Store, key: []const u8) ?i64 {
        assert(key.len > 0);
        const slot = self.findSlot(keyHash(key), key) orelse return null;
        return self.entries[self.slots[slot].idx].expires_at;
    }

    pub inline fn persist(self: *Store, key: []const u8) bool {
        assert(key.len > 0);
        const slot = self.findSlot(keyHash(key), key) orelse return false;
        const entry = self.entries[self.slots[slot].idx];
        if (entry.expires_at == null) return false;

        entry.expires_at = null;
        if (self.tracks_volatile_entries()) {
            self.detach_volatile(entry);
        }
        self.touch_entry(entry);
        return true;
    }

    pub inline fn random_key(self: *Store, random: std.Random) ?[]const u8 {
        const total_keys = self.count;
        if (total_keys == 0) return null;

        const random_idx = random.intRangeAtMost(usize, 0, total_keys - 1);

        var current_idx: usize = 0;
        for (self.slots) |s| {
            if (s.idx == empty_slot or s.idx == tomb_slot) continue;
            if (current_idx == random_idx) {
                return self.entries[s.idx].key;
            }
            current_idx += 1;
        }

        return null;
    }

    pub inline fn flush_db(self: *Store) void {
        for (self.slots) |s| {
            if (s.idx == empty_slot or s.idx == tomb_slot) continue;
            self.free_entry_contents(self.entries[s.idx]);
        }
        for (self.slots) |*s| s.* = .{ .hash = 0, .idx = empty_slot };
        for (self.entries) |entry| {
            self.allocator.destroy(entry);
        }
        self.free_entries_array();
        self.free_head = no_entry;
        self.count = 0;
        self.lru_head = null;
        self.lru_tail = null;
        self.volatile_lru_head = null;
        self.volatile_lru_tail = null;
        self.allkeys_sample_cursor = null;
        self.volatile_sample_cursor = null;
        self.deletions_since_rehash = 0;
    }

    fn evict_expired_volatile(self: *Store) bool {
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

    fn sample_global_victim(self: *Store) ?*StoreEntry {
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

    fn sample_volatile_victim(self: *Store) ?*StoreEntry {
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

    pub fn evict_one(self: *Store, policy: Config.EvictionPolicy) bool {
        switch (policy) {
            .noeviction => return false,
            .allkeys_lru => {
                if (self.evict_expired_volatile()) return true;
                const victim = self.sample_global_victim() orelse return false;
                return self.delete(victim.key);
            },
            .volatile_lru => {
                if (self.evict_expired_volatile()) return true;
                const victim = self.sample_volatile_victim() orelse return false;
                return self.delete(victim.key);
            },
        }
    }

    pub fn rename_key(self: *Store, old_key: []const u8, new_key: []const u8) !bool {
        assert(old_key.len > 0);
        assert(new_key.len > 0);

        if (std.mem.eql(u8, old_key, new_key)) {
            return self.resolve_entry(old_key, false) != null;
        }

        const entry = self.resolve_entry(old_key, false) orelse return false;

        if (self.findSlot(keyHash(new_key), new_key) != null) {
            _ = self.delete(new_key);
        }

        if (new_key.len > inline_key_max) {
            const new_heap = try self.allocator.dupe(u8, new_key);
            if (entry.key.len > inline_key_max) self.allocator.free(entry.key);
            entry.key = new_heap;
        } else {
            if (entry.key.len > inline_key_max) self.allocator.free(entry.key);
            @memcpy(entry.inline_key_data[0..new_key.len], new_key);
            entry.key = entry.inline_key_data[0..new_key.len];
        }

        const old_slot = self.findSlot(keyHash(old_key), old_key) orelse unreachable;
        const idx = self.slots[old_slot].idx;
        self.slots[old_slot] = .{ .hash = 0, .idx = tomb_slot };
        self.count -= 1;

        const new_h32 = keyHash(new_key);
        const slot = self.findInsertSlot(new_h32);
        self.slots[slot] = .{ .hash = new_h32, .idx = idx };
        self.count += 1;

        self.touch_entry(entry);
        return true;
    }

    pub fn create_time_series(self: *Store, key: []const u8, ts: TimeSeries) !void {
        assert(key.len > 0);
        const ts_ptr = try self.allocator.create(TimeSeries);
        errdefer self.allocator.destroy(ts_ptr);

        ts_ptr.* = ts;
        try self.put_object(key, .{ .value = .{ .time_series = ts_ptr } });
    }

    pub inline fn maybe_maintenance(self: *Store) void {
        const now = self.clock.now().toMilliseconds();
        if (now - self.last_maintenance_check < 50) return;
        self.last_maintenance_check = now;

        const cap = self.slots.len;
        if (cap == 0) return;

        const entry_count = self.count;
        const waste = cap - entry_count;

        if ((waste > cap / 2) or (self.deletions_since_rehash > cap / 4)) {
            self.maintenance();
        }
    }

    pub fn maintenance(self: *Store) void {
        const cap = self.slots.len;
        const entry_count = self.count;

        if (cap == 0) {
            self.deletions_since_rehash = 0;
            return;
        }

        if (entry_count == 0) {
            if (self.deletions_since_rehash > 0) {
                self.rebuildSlots(16) catch return;
            }
            self.deletions_since_rehash = 0;
            return;
        }

        const estimated_waste_ratio = @as(f64, @floatFromInt(cap - entry_count)) /
            @as(f64, @floatFromInt(cap));

        const should_rehash = (estimated_waste_ratio > 0.5) or
            (self.deletions_since_rehash > cap / 4);

        if (should_rehash) {
            self.rebuildSlots(entry_count * 2) catch return;
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
    try testing.expectEqualStrings("hello", result.?.value.short_string.as_slice());
}

test "Store set_int and get" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set_int("counter", 42);
    try testing.expectEqual(@as(u32, 1), store.size());

    const result = store.get("counter");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 42), result.?.value.int);
}

test "Store setObject with ZedisObject" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const obj = ZedisObject{ .value = .{ .string = try testing.allocator.dupe(u8, "test") } };
    defer testing.allocator.free(obj.value.string);
    try store.put_object("key1", obj);

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

test "Store get_type" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expect(store.get_type("nonexistent") == null);

    try store.set("str_key", "hello");
    try testing.expectEqual(ValueType.short_string, store.get_type("str_key").?);

    try store.set_int("int_key", 42);
    try testing.expectEqual(ValueType.int, store.get_type("int_key").?);
}

test "Store overwrite existing key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "original");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result1 = store.get("key1");
    try testing.expect(result1 != null);
    try testing.expectEqualStrings("original", result1.?.value.short_string.as_slice());

    try store.set("key1", "updated");
    try testing.expectEqual(@as(u32, 1), store.size());

    const result2 = store.get("key1");
    try testing.expect(result2 != null);
    try testing.expectEqualStrings("updated", result2.?.value.short_string.as_slice());
}

test "Store overwrite string with integer" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.get_type("key1").?);

    try store.set_int("key1", 123);
    try testing.expectEqual(ValueType.int, store.get_type("key1").?);
    try testing.expectEqual(@as(i64, 123), store.get("key1").?.value.int);
}

test "Store overwrite integer with string" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set_int("key1", 456);
    try testing.expectEqual(ValueType.int, store.get_type("key1").?);

    try store.set("key1", "world");
    try testing.expectEqual(ValueType.short_string, store.get_type("key1").?);
    try testing.expectEqualStrings("world", store.get("key1").?.value.short_string.as_slice());
}

test "Store expire functionality" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "value1");
    try testing.expect(!store.is_expired("key1"));

    // Set expiration to far future
    const now = Io.Clock.real.now(testing.io);
    const future_time = now.toMilliseconds() + 1000000;
    const success = try store.expire("key1", future_time);
    try testing.expect(success);
    try testing.expect(!store.is_expired("key1"));
    try testing.expect(store.get("key1") != null);
    try testing.expectEqual(future_time, store.get_ttl("key1").?);

    // Set expiration to past
    const past_time: i64 = 12345;
    _ = try store.expire("key1", past_time);
    try testing.expect(store.is_expired("key1"));
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
    try testing.expect(!store.is_expired("key1"));
}

test "Store multiple keys with different types" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.set_int("int1", 123);
    try store.set_int("int2", -456);

    try testing.expectEqual(@as(u32, 4), store.size());

    try testing.expectEqualStrings("hello", store.get("str1").?.value.short_string.as_slice());
    try testing.expectEqualStrings("world", store.get("str2").?.value.short_string.as_slice());
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
    try testing.expectEqualStrings("", result.?.value.short_string.as_slice());
}

test "Store zero integer values" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set_int("zero", 0);

    const result = store.get("zero");
    try testing.expect(result != null);
    try testing.expectEqual(@as(i64, 0), result.?.value.int);
}

test "Store create_list and get_list" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try testing.expect(try store.get_list("mylist") == null);

    const list = try store.create_list("mylist");
    try testing.expectEqual(@as(usize, 0), list.len());

    const retrieved_list = try store.get_list("mylist");
    try testing.expect(retrieved_list != null);
    try testing.expectEqual(@as(usize, 0), retrieved_list.?.len());
}

test "Store list append and insert operations" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.create_list("test_append_insert");

    try testing.expectEqual(@as(usize, 0), list.len());

    try list.append(.{ .string = try testing.allocator.dupe(u8, "first") });
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("first", list.get_by_index(0).?.string);

    try list.append(.{ .string = try testing.allocator.dupe(u8, "second") });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqualStrings("second", list.get_by_index(1).?.string);

    try list.prepend(.{ .string = try testing.allocator.dupe(u8, "zero") });
    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expectEqualStrings("zero", list.get_by_index(0).?.string);
    try testing.expectEqualStrings("first", list.get_by_index(1).?.string);
    try testing.expectEqualStrings("second", list.get_by_index(2).?.string);
}

test "Store list with mixed value types" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.create_list("test_mixed_values");

    try list.append(.{ .string = try testing.allocator.dupe(u8, "hello") });
    try list.append(.{ .int = 42 });
    try list.append(.{ .string = try testing.allocator.dupe(u8, "world") });

    try testing.expectEqual(@as(usize, 3), list.len());
    try testing.expectEqualStrings("hello", list.get_by_index(0).?.string);
    try testing.expectEqual(@as(i64, 42), list.get_by_index(1).?.int);
    try testing.expectEqualStrings("world", list.get_by_index(2).?.string);
}

test "Store get_list with wrong type" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("notalist", "hello");

    const list = store.get_list("notalist");
    try testing.expect(list == error.WrongType);
}

test "Store list type checking" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    _ = try store.create_list("mylist");
    try testing.expectEqual(ValueType.list, store.get_type("mylist").?);
}

test "Store overwrite string with list" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.get_type("key1").?);

    _ = try store.create_list("key1");
    try testing.expectEqual(ValueType.list, store.get_type("key1").?);

    const list = try store.get_list("key1");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 0), list.?.len());
}

test "Store overwrite list with string" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.create_list("key1");
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item") });
    try testing.expectEqual(ValueType.list, store.get_type("key1").?);

    try store.set("key1", "hello");
    try testing.expectEqual(ValueType.short_string, store.get_type("key1").?);
    try testing.expectEqualStrings("hello", store.get("key1").?.value.short_string.as_slice());

    const retrieved_list = store.get_list("key1");
    try testing.expect(retrieved_list == error.WrongType);
}

test "Store delete list key" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.create_list("mylist");
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item2") });

    try testing.expect(store.exists("mylist"));
    try testing.expectEqual(@as(u32, 1), store.size());

    const deleted = store.delete("mylist");
    try testing.expect(deleted);
    try testing.expect(!store.exists("mylist"));
    try testing.expectEqual(@as(u32, 0), store.size());
    try testing.expect(try store.get_list("mylist") == null);
}

test "Store empty list operations" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    const list = try store.create_list("test_empty_ops");
    try testing.expectEqual(@as(usize, 0), list.len());

    try list.append(.{ .string = try testing.allocator.dupe(u8, "") });
    try testing.expectEqual(@as(usize, 1), list.len());
    try testing.expectEqualStrings("", list.get_by_index(0).?.string);

    try list.append(.{ .int = 0 });
    try testing.expectEqual(@as(usize, 2), list.len());
    try testing.expectEqual(@as(i64, 0), list.get_by_index(1).?.int);
}

test "Store flush_db removes all keys" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    // Add various types of keys
    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.set_int("int1", 42);
    try store.set_int("int2", -100);

    const list = try store.create_list("mylist");
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item2") });

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
    try testing.expect(try store.get_list("mylist") == null);
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
    try store.set_int("key2", 123);
    try testing.expectEqual(@as(u32, 2), store.size());

    // Flush
    store.flush_db();
    try testing.expectEqual(@as(u32, 0), store.size());

    // Add new keys after flush
    try store.set("key3", "value3");
    try store.set_int("key4", 456);
    try testing.expectEqual(@as(u32, 2), store.size());

    // Verify new keys work correctly
    try testing.expectEqualStrings("value3", store.get("key3").?.value.short_string.as_slice());
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
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity_before = store.capacity();
    const size_before = @as(usize, store.size());
    try testing.expect(capacity_before > 0);
    try testing.expectEqual(@as(usize, 1000), size_before);

    // Delete half the keys to create tombstones
    i = 0;
    while (i < 500) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        const deleted = store.delete(key);
        try testing.expect(deleted);
    }

    const size_after_delete = @as(usize, store.size());
    try testing.expectEqual(@as(usize, 500), size_after_delete);

    // Deletes may trigger automatic maintenance, but capacity should never grow here.
    try testing.expect(store.capacity() <= capacity_before);

    // Run maintenance to clean up tombstones
    store.maintenance();

    const capacity_after = store.capacity();
    const size_after = @as(usize, store.size());

    // Size should remain the same
    try testing.expectEqual(@as(usize, 500), size_after);

    // Capacity should be reduced or at least not larger
    try testing.expect(capacity_after <= capacity_before);

    // Verify remaining keys are still accessible
    i = 500;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        const result = store.get(key);
        try testing.expect(result != null);
        try testing.expectEqualStrings("value", result.?.value.short_string.as_slice());
    }
}

test "Store maintenance() resets deletion counter" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add and delete keys to increment deletion counter
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
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

test "Store maybe_maintenance() respects rate limiting" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add enough keys to trigger capacity growth
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    // Delete many keys to exceed threshold
    i = 0;
    while (i < 700) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    const capacity_before = store.capacity();

    // Reset last_maintenance_check to ensure our explicit call isn't rate-limited
    // (delete() calls maybe_maintenance() automatically, which may have updated it recently)
    store.last_maintenance_check = 0;
    const last_check_before = store.last_maintenance_check;

    // Call maybe_maintenance multiple times in quick succession
    store.maybe_maintenance();
    const capacity_after_first = store.capacity();
    const last_check_after_first = store.last_maintenance_check;

    // First call should trigger maintenance
    try testing.expect(capacity_after_first <= capacity_before);
    try testing.expect(last_check_after_first > last_check_before);

    // Immediately call again (within 50ms)
    store.maybe_maintenance();
    const capacity_after_second = store.capacity();
    const last_check_after_second = store.last_maintenance_check;

    // Second call should be rate-limited (no maintenance)
    try testing.expectEqual(capacity_after_first, capacity_after_second);
    try testing.expectEqual(last_check_after_first, last_check_after_second);
}

test "Store maybe_maintenance() triggers on 50% waste threshold" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add many keys
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity_before = store.capacity();

    // Delete more than 50% of capacity to trigger waste threshold
    // (capacity - count) > capacity / 2
    const target_deletions = (capacity_before / 2) + 10;
    i = 0;
    while (i < target_deletions) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    // Reset last_maintenance_check to avoid rate limiting
    store.last_maintenance_check = 0;

    // This should trigger maintenance due to waste threshold
    store.maybe_maintenance();

    // Deletion counter should be reset after maintenance
    try testing.expectEqual(@as(usize, 0), store.deletions_since_rehash);
}

test "Store maybe_maintenance() triggers on 25% deletions threshold" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    // Add keys to establish capacity
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity = store.capacity();
    const threshold = capacity / 4;

    // Block the implicit maintenance calls inside delete() so this test can
    // deterministically verify the explicit maybe_maintenance() invocation.
    store.last_maintenance_check = store.clock.now().toMilliseconds() + 60_000;

    // Delete exactly threshold + 1 keys to trigger maintenance
    i = 0;
    while (i < threshold + 1) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    try testing.expectEqual(threshold + 1, store.deletions_since_rehash);

    // Reset last_maintenance_check to avoid rate limiting
    store.last_maintenance_check = 0;

    // This should trigger maintenance due to deletion threshold
    store.maybe_maintenance();

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

test "Store evict_one allkeys_lru evicts least recently used key" {
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

    try testing.expect(store.evict_one(.allkeys_lru));
    try testing.expect(store.get("key2") == null);
    try testing.expect(store.get("key1") != null);
    try testing.expect(store.get("key3") != null);
}

test "Store evict_one volatile_lru only evicts volatile keys" {
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

    try testing.expect(store.evict_one(.volatile_lru));
    try testing.expect(store.get("ttl2") == null);
    try testing.expect(store.get("ttl1") != null);
    try testing.expect(store.get("persistent") != null);
}

test "Store evict_one prefers expired ttl entries before LRU tail" {
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

    try testing.expect(store.evict_one(.allkeys_lru));
    try testing.expect(store.get("expired") == null);
    try testing.expect(store.get("fresh1") != null);
    try testing.expect(store.get("fresh2") != null);
}
