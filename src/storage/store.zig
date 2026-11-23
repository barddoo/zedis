const std = @import("std");
const ZedisList = @import("list.zig").ZedisList;
const ZedisHash = @import("hash.zig").ZedisHash;
const ZedisSet = @import("set.zig").ZedisSet;
const ZedisZSet = @import("zset.zig").ZedisZSet;
const ts_module = @import("time_series.zig");
const TimeSeries = ts_module.TimeSeries;
const Io = std.Io;
const Clock = @import("../app/clock.zig");
const Config = @import("../app/config.zig");
const string_match = @import("../util/string_match.zig").string_match;
const Stats = @import("../app/stats.zig");
const StoreCounters = Stats.StoreCounters;
const ScalableBloomFilter = @import("bloom/bloom.zig").BloomFilter;
const SearchIndex = @import("search/index.zig").SearchIndex;
pub const ShortString = @import("../util/types.zig").ShortString;
pub const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;

const assert = std.debug.assert;

// Optimal load factor
const optimal_max_load_percentage = 80;

// Keys up to this many bytes are stored inline in the entry (no heap allocation).
const inline_key_max = 23;

const testing = std.testing;

pub const ValueType = enum(u8) {
    string = 0,
    int = 1,
    list,
    short_string,
    time_series,
    bloom_filter,
    search_index,
    hash_map = 7,
    set = 8,
    zset = 9,

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
    hash_map: *ZedisHash,
    set: *ZedisSet,
    zset: *ZedisZSet,
};

pub const ZedisObject = struct {
    value: ZedisValue,
};

// Open-addressing hash table slot: stored hash (fast probing) + entry index.
// Deletion shifts the rest of the probe cluster down (see `shiftBackward`), so
// there are no tombstones.
const empty_slot: u32 = std.math.maxInt(u32);
const no_entry: u32 = std.math.maxInt(u32);

const Slot = struct {
    hash: u32,
    idx: u32,
};

/// Eviction is a clock sweep over `entries`. Each live entry carries a saturating
/// reference counter; the hand decrements it as it passes and evicts the first
/// entry it finds at zero, so the sweep *is* the aging step. This is Postgres'
/// `usage_count` scheme.
///
/// The cap is 5, matching `BM_MAX_USAGE_COUNT`. One bit would be cheaper to
/// sweep but cannot tell a key read six times from a key read once, so a hot set
/// loses to a one-shot scan: measured hot-set survival after a scan of one
/// cache-capacity in new keys was 100% at 5 and 3% at 1, for ~12% more sweep
/// time. Five is the smallest cap that keeps the working set alive.
const ref_max: u8 = 5;

const StoreEntry = struct {
    key: []const u8,
    inline_key_data: [inline_key_max]u8,
    object: ZedisObject,
    expires_at: ?i64 = null,
    /// Low three bits are the reference counter, the top bit marks a live entry:
    /// the free list leaves holes in `entries` and the sweep has to skip them.
    /// Costs nothing, because it fills padding the struct already had.
    ref: u8 = ref_free,
    next_free: u32 = no_entry,
};

const ref_live_bit: u8 = 0x80;
const ref_count_mask: u8 = 0x07;
/// A cleared counter and no live bit: what a slot on the free list looks like.
const ref_free: u8 = 0;

/// Smallest power-of-two slot count that keeps `count` at or below 50% load.
fn shrinkTarget(count: usize) usize {
    var target: usize = 16;
    while (target < count * 2) target *= 2;
    return target;
}

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
            if (s.idx == empty_slot) continue;
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

pub const ScanEntryView = struct {
    /// Slot the entry was read from; pass `ScanIterator.slot_index` back as the
    /// next SCAN cursor to resume after it.
    slot: usize,
    key: []const u8,
    value_type: ValueType,
    expires_at: ?i64,
};

pub const ScanIterator = struct {
    store: *const Store,
    slot_index: usize,

    pub fn next(self: *ScanIterator) ?ScanEntryView {
        while (self.slot_index < self.store.slots.len) {
            const slot = self.slot_index;
            self.slot_index += 1;
            const s = self.store.slots[slot];
            if (s.idx == empty_slot) continue;
            const entry = self.store.entries[s.idx];
            return .{
                .slot = slot,
                .key = entry.key,
                .value_type = std.meta.activeTag(entry.object.value),
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

    /// Clock hand: an index into `entries`, kept masked to `entries.len`. It
    /// survives across evictions so successive victims continue around the ring
    /// instead of restarting at the oldest slot.
    clock_hand: u32,
    /// Entry the clock must not evict: a caller holds a pointer to it across an
    /// allocation that can trigger eviction (an in-place update clones its new
    /// value first). A pointer, not an index, because reclaiming memory
    /// renumbers the index space while the pin is still held.
    pinned: ?*StoreEntry,

    last_maintenance_check: i64,
    eviction_policy: Config.EvictionPolicy,
    /// Accepted for Redis config compatibility. The clock sweep has no sample
    /// size, so this is inert; it is kept on the struct because
    /// `CONFIG GET/SET maxmemory-samples` still round-trips it.
    maxmemory_samples: usize,

    /// Hits/misses and expiry/eviction counts for INFO and METRICS. Plain u64:
    /// the single executor owns all store mutations.
    counters: StoreCounters = .{},
    /// Set by the server while a read-only command runs with a configured
    /// `command-timeout-ms`; see `commandExpired`.
    command_deadline_ns: ?u64 = null,

    pub fn commandExpired(self: *const Store) bool {
        const deadline = self.command_deadline_ns orelse return false;
        return Stats.nowNs(self.io) >= deadline;
    }

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
            if (s.hash == h32) {
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
        while (self.slots[i].idx != empty_slot) {
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
                if (s.idx == empty_slot) continue;
                var i: usize = @as(usize, s.hash) & mask;
                while (new_slots[i].idx != empty_slot) i = (i + 1) & mask;
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
            .clock_hand = 0,
            .pinned = null,
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
            if (s.idx == empty_slot) continue;
            self.free_entry_contents(s.idx);
        }
        for (self.entries) |entry| {
            self.allocator.destroy(entry);
        }
        if (self.slots.len > 0) self.allocator.free(self.slots);
        self.free_entries_array();
        self.slots = &.{};
        self.clock_hand = 0;
        self.pinned = null;
    }

    pub fn iterator(self: *const Store) Iterator {
        return .{ .store = self, .slot_index = 0 };
    }

    pub fn scanIterator(self: *const Store, start: usize) ScanIterator {
        return .{ .store = self, .slot_index = start };
    }

    pub inline fn size(self: Store) u32 {
        return @intCast(self.count);
    }

    pub inline fn capacity(self: *const Store) usize {
        return self.slots.len;
    }

    /// Removes `hole` from its probe cluster and shifts the entries behind it
    /// down, so a lookup can still stop at the first empty slot. An entry at
    /// `j` may move into the hole when the hole is not before its home slot
    /// in probe order; otherwise the gap is still part of its probe chain.
    fn shiftBackward(self: *Store, hole: usize) void {
        const mask = self.slots.len - 1;
        var h = hole;
        var j = (h + 1) & mask;
        self.slots[h] = .{ .hash = 0, .idx = empty_slot };
        var remaining: usize = self.slots.len;
        while (remaining > 0) : (remaining -= 1) {
            const s = self.slots[j];
            if (s.idx == empty_slot) return;
            const home = @as(usize, s.hash) & mask;
            if (((j -% home) & mask) >= ((j -% h) & mask)) {
                self.slots[h] = s;
                h = j;
                self.slots[j] = .{ .hash = 0, .idx = empty_slot };
            }
            j = (j + 1) & mask;
        }
    }

    fn delete_at_slot(self: *Store, slot: usize) void {
        const idx = self.slots[slot].idx;
        self.shiftBackward(slot);
        self.count -= 1;
        self.free_entry_contents(idx);
        const entry = self.entries[idx];
        entry.next_free = self.free_head;
        self.free_head = idx;
        self.maybe_maintenance();
    }

    // --- Reference counters and the clock hand -----------------------------

    inline fn refOf(self: *const Store, idx: u32) u8 {
        return self.entries[idx].ref & ref_count_mask;
    }

    inline fn isLive(self: *const Store, idx: u32) bool {
        return (self.entries[idx].ref & ref_live_bit) != 0;
    }

    inline fn setRef(self: *Store, idx: u32, count: u8) void {
        assert(count <= ref_max);
        self.entries[idx].ref = ref_live_bit | count;
    }

    inline fn markDead(self: *Store, idx: u32) void {
        self.entries[idx].ref = ref_free;
    }

    /// Records an access. A counter already at the cap is left alone, which
    /// keeps steady-state reads of hot keys write-free.
    inline fn noteAccess(self: *Store, idx: u32) void {
        const current = self.refOf(idx);
        if (current < ref_max) self.setRef(idx, current + 1);
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
            .hash_map => {},
            .set => {},
            .zset => {},
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
            .hash_map => |h_ptr| h_ptr.deinit(),
            .set => |s_ptr| s_ptr.deinit(),
            .zset => |z_ptr| z_ptr.deinit(),
        }
    }

    fn free_entry_contents(self: *Store, idx: u32) void {
        const entry = self.entries[idx];
        self.markDead(idx);
        self.free_object_value(entry.object);
        if (entry.key.len > inline_key_max) self.allocator.free(entry.key);
    }

    fn resolve_entry(self: *Store, key: []const u8, touch: bool) ?*StoreEntry {
        const slot = self.findSlot(keyHash(key), key) orelse {
            self.counters.keyspace_misses += 1;
            return null;
        };
        const idx = self.slots[slot].idx;
        const entry = self.entries[idx];

        if (entry.expires_at) |expiration_time| {
            const now = self.clock.now().toMilliseconds();
            if (now > expiration_time) {
                self.counters.expired_keys += 1;
                self.counters.keyspace_misses += 1;
                self.delete_at_slot(slot);
                return null;
            }
        }

        self.counters.keyspace_hits += 1;
        if (touch) self.noteAccess(idx);
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
            const idx = self.slots[slot].idx;
            const entry = self.entries[idx];
            if (std.meta.activeTag(entry.object.value) == .time_series) {
                return error.AlreadyExists;
            }

            // The replacement value is cloned through the budgeted allocator,
            // which can evict. `entry` is written below, so the clock must not
            // take it while that allocation is in flight.
            self.noteAccess(idx);
            const previous_pin = self.pinned;
            self.pinned = entry;
            defer self.pinned = previous_pin;

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
        };
        // One pass of grace for a freshly written key, matching the
        // `usage_count = 1` Postgres leaves on a page it just read in.
        self.setRef(idx, 1);

        try self.setEntryKey(entry, key);

        const slot = self.findInsertSlot(h32);
        self.slots[slot] = .{ .hash = h32, .idx = idx };
        self.count += 1;
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

        for (self.slots, 0..) |s, index| {
            if (index % 1024 == 0 and self.commandExpired()) {
                result.deinit(allocator);
                return error.CommandTimeout;
            }
            if (s.idx == empty_slot) continue;
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

    pub fn get_hash(self: *Store, key: []const u8) !?*ZedisHash {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;
        switch (entry.object.value) {
            .hash_map => |h| return h,
            else => return error.WrongType,
        }
    }

    pub fn create_hash(self: *Store, key: []const u8) !*ZedisHash {
        assert(key.len > 0);
        const h = try ZedisHash.init(self.allocator);
        errdefer h.deinit();
        try self.put_object(key, .{ .value = .{ .hash_map = h } });
        return self.resolve_entry(key, true).?.object.value.hash_map;
    }

    pub fn get_or_create_hash(self: *Store, key: []const u8) !*ZedisHash {
        return (try self.get_hash(key)) orelse try self.create_hash(key);
    }

    pub fn get_set(self: *Store, key: []const u8) !?*ZedisSet {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;
        switch (entry.object.value) {
            .set => |s| return s,
            else => return error.WrongType,
        }
    }

    pub fn create_set(self: *Store, key: []const u8) !*ZedisSet {
        assert(key.len > 0);
        const s = try ZedisSet.init(self.allocator);
        errdefer s.deinit();
        try self.put_object(key, .{ .value = .{ .set = s } });
        return self.resolve_entry(key, true).?.object.value.set;
    }

    pub fn get_or_create_set(self: *Store, key: []const u8) !*ZedisSet {
        return (try self.get_set(key)) orelse try self.create_set(key);
    }

    pub fn get_zset(self: *Store, key: []const u8) !?*ZedisZSet {
        assert(key.len > 0);
        const entry = self.resolve_entry(key, true) orelse return null;
        switch (entry.object.value) {
            .zset => |z| return z,
            else => return error.WrongType,
        }
    }

    pub fn create_zset(self: *Store, key: []const u8) !*ZedisZSet {
        assert(key.len > 0);
        const z = try ZedisZSet.init(self.allocator);
        errdefer z.deinit();
        try self.put_object(key, .{ .value = .{ .zset = z } });
        return self.resolve_entry(key, true).?.object.value.zset;
    }

    pub fn get_or_create_zset(self: *Store, key: []const u8) !*ZedisZSet {
        return (try self.get_zset(key)) orelse try self.create_zset(key);
    }

    pub fn expire(self: *Store, key: []const u8, time: i64) !bool {
        assert(key.len > 0);
        assert(time > 0);

        const slot = self.findSlot(keyHash(key), key) orelse return false;
        const idx = self.slots[slot].idx;
        self.entries[idx].expires_at = time;
        self.noteAccess(idx);
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
        const idx = self.slots[slot].idx;
        const entry = self.entries[idx];
        if (entry.expires_at == null) return false;

        entry.expires_at = null;
        self.noteAccess(idx);
        return true;
    }

    pub inline fn random_key(self: *Store, random: std.Random) ?[]const u8 {
        const total_keys = self.count;
        if (total_keys == 0) return null;

        const random_idx = random.intRangeAtMost(usize, 0, total_keys - 1);

        var current_idx: usize = 0;
        for (self.slots) |s| {
            if (s.idx == empty_slot) continue;
            if (current_idx == random_idx) {
                return self.entries[s.idx].key;
            }
            current_idx += 1;
        }

        return null;
    }

    /// Releases allocator capacity that no longer holds live data: destroys the
    /// free-list entries and shrinks the entry and slot arrays. Called from the
    /// KV allocator at a command boundary, when eviction alone cannot get under
    /// budget, so no pointers into the store are live.
    ///
    /// Returns false when there is nothing to reclaim.
    pub fn reclaim_memory(self: *Store) bool {
        var needed_capacity: usize = 16;
        while (needed_capacity < self.count) needed_capacity *= 2;

        const target_slots = if (self.count == 0) 16 else self.count + self.count / 4 + 1;
        var slots_target: usize = 16;
        while (slots_target < target_slots) slots_target *= 2;

        const has_free_entries = self.free_head != no_entry;
        const entries_oversized = self.entries_capacity > needed_capacity;
        const slots_oversized = self.slots.len >= slots_target * 2;

        if (!has_free_entries and !entries_oversized and !slots_oversized) return false;

        var reclaimed = false;

        if (has_free_entries or entries_oversized) {
            // Allocate before mutating: if this fails, the store stays intact.
            const new_entries = self.allocator.alloc(*StoreEntry, needed_capacity) catch return false;

            var write: usize = 0;
            for (self.slots) |*slot| {
                if (slot.idx == empty_slot) continue;
                new_entries[write] = self.entries[slot.idx];
                slot.idx = @intCast(write);
                write += 1;
            }
            std.debug.assert(write == self.count);

            // Only now that live pointers are copied out can the pooled entries go.
            var idx = self.free_head;
            while (idx != no_entry) {
                const entry = self.entries[idx];
                idx = entry.next_free;
                self.allocator.destroy(entry);
            }

            self.free_entries_array();
            self.entries = new_entries[0..self.count];
            self.entries_capacity = needed_capacity;
            self.free_head = no_entry;
            // Every index just moved; restart the hand at the front of the new
            // numbering rather than in the middle of a permutation.
            self.clock_hand = 0;
            reclaimed = true;
        }

        if (self.slots.len >= slots_target * 2) {
            const previous_len = self.slots.len;
            self.rebuildSlots(slots_target) catch {};
            if (self.slots.len < previous_len) reclaimed = true;
        }

        return reclaimed;
    }

    pub inline fn flush_db(self: *Store) void {
        for (self.slots) |s| {
            if (s.idx == empty_slot) continue;
            self.free_entry_contents(s.idx);
        }
        for (self.slots) |*s| s.* = .{ .hash = 0, .idx = empty_slot };
        for (self.entries) |entry| {
            self.allocator.destroy(entry);
        }
        self.free_entries_array();
        self.free_head = no_entry;
        self.count = 0;
        self.clock_hand = 0;
        self.pinned = null;
    }

    const Victim = struct {
        entry: *StoreEntry,
        expired: bool,
    };

    /// Advances the clock until it finds a live, eligible entry whose counter
    /// has run out. Entries past their TTL are taken as soon as the hand reaches
    /// them, which is what the old separate expired-key scan did.
    ///
    /// Bounded by `ref_max + 1` laps: one lap clears every counter once, so a
    /// full set of them has to reach zero before anything can be declared
    /// unevictable. Returning null sends `enforce_budget` down its reclaim path
    /// instead of spinning here.
    fn sweep(self: *Store, volatile_only: bool) ?Victim {
        const len: u32 = @intCast(self.entries.len);
        if (self.count == 0 or len == 0) return null;
        if (self.clock_hand >= len) self.clock_hand = 0;

        var budget: usize = @as(usize, len) * @as(usize, ref_max + 1);
        const now = self.clock.now().toMilliseconds();

        while (budget > 0) : (budget -= 1) {
            const idx = self.clock_hand;
            self.clock_hand = if (idx + 1 == len) 0 else idx + 1;

            if (!self.isLive(idx)) continue;

            const entry = self.entries[idx];
            if (self.pinned) |pinned| {
                if (entry == pinned) continue;
            }
            if (volatile_only and entry.expires_at == null) continue;
            if (entry.expires_at) |expiration_time| {
                if (now > expiration_time) return .{ .entry = entry, .expired = true };
            }

            const count = self.refOf(idx);
            if (count == 0) return .{ .entry = entry, .expired = false };
            self.setRef(idx, count - 1);
        }

        return null;
    }

    pub fn evict_one(self: *Store, policy: Config.EvictionPolicy) bool {
        const victim = switch (policy) {
            .noeviction => return false,
            .allkeys_lru => self.sweep(false) orelse return false,
            .volatile_lru => self.sweep(true) orelse return false,
        };

        const removed = self.delete(victim.entry.key);
        if (removed) {
            if (victim.expired) {
                self.counters.expired_keys += 1;
            } else {
                self.counters.evicted_keys += 1;
            }
        }
        return removed;
    }

    pub fn rename_key(self: *Store, old_key: []const u8, new_key: []const u8) !bool {
        assert(old_key.len > 0);
        assert(new_key.len > 0);

        if (std.mem.eql(u8, old_key, new_key)) {
            return self.resolve_entry(old_key, false) != null;
        }

        // Pin the entry across the allocation below: it is the only thing in the
        // store the clock must not take while the new key bytes are allocated.
        const pinned_slot = self.findSlot(keyHash(old_key), old_key) orelse return false;
        const pinned_entry = self.entries[self.slots[pinned_slot].idx];
        self.noteAccess(self.slots[pinned_slot].idx);
        const previous_pin = self.pinned;
        self.pinned = pinned_entry;
        defer self.pinned = previous_pin;

        const new_heap: ?[]u8 = if (new_key.len > inline_key_max) try self.allocator.dupe(u8, new_key) else null;
        errdefer if (new_heap) |key| self.allocator.free(key);

        if (self.findSlot(keyHash(new_key), new_key) != null) {
            _ = self.delete(new_key);
        }

        // Look the old key up only now: the allocation (eviction) and the delete
        // (and its backward-shift) above can both move or remove slots. The
        // entry still carries its old key here, so this finds it unless it was
        // evicted.
        const old_slot = self.findSlot(keyHash(old_key), old_key) orelse {
            if (new_heap) |key| self.allocator.free(key);
            return false;
        };
        const idx = self.slots[old_slot].idx;
        const entry = self.entries[idx];

        if (entry.key.len > inline_key_max) self.allocator.free(entry.key);
        if (new_heap) |key| {
            entry.key = key;
        } else {
            @memcpy(entry.inline_key_data[0..new_key.len], new_key);
            entry.key = entry.inline_key_data[0..new_key.len];
        }

        // Remove the old mapping without touching the entry: it is re-inserted
        // under the new key below, so the live count does not change.
        self.shiftBackward(old_slot);

        const new_h32 = keyHash(new_key);
        const slot = self.findInsertSlot(new_h32);
        self.slots[slot] = .{ .hash = new_h32, .idx = idx };

        self.noteAccess(idx);
        return true;
    }

    /// Copy `src` to `dst`. Returns false if `src` does not exist.
    /// Returns error.AlreadyExists if `dst` exists and `replace` is false.
    /// Only supports scalar types (string, int, short_string); returns
    /// error.WrongType for complex types.
    pub fn copy_key(self: *Store, src: []const u8, dst: []const u8, replace: bool) !bool {
        assert(src.len > 0);
        assert(dst.len > 0);

        const src_obj = self.get(src) orelse return false;

        if (self.get(dst) != null) {
            if (!replace) return error.AlreadyExists;
            _ = self.delete(dst);
        }

        switch (src_obj.value) {
            .string => |s| try self.set(dst, s),
            .short_string => |ss| try self.set(dst, ss.as_slice()),
            .int => |i| try self.set_int(dst, i),
            else => return error.WrongType,
        }

        if (self.get_ttl(src)) |expires_at| {
            _ = try self.expire(dst, expires_at);
        }

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
        if (self.slots.len <= 16) return;

        // Only rehash when the table can actually shrink; checking that first
        // keeps the common delete path from reading the clock or rehashing for
        // no gain.
        if (shrinkTarget(self.count) >= self.slots.len) return;

        const now = self.clock.now().toMilliseconds();
        if (now - self.last_maintenance_check < 50) return;
        self.last_maintenance_check = now;
        self.maintenance();
    }

    /// Rebuilds the table into the smallest power-of-two capacity that keeps
    /// the load factor at or below 50%. Deletions leave no tombstones (see
    /// `shiftBackward`), so this only reclaims capacity.
    pub fn maintenance(self: *Store) void {
        const cap = self.slots.len;
        if (cap == 0) return;

        const target = shrinkTarget(self.count);
        if (target < cap) self.rebuildSlots(target) catch return;
    }
};

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

    const now = Io.Clock.real.now(testing.io);
    const future_time = now.toMilliseconds() + 1000000;
    const success = try store.expire("key1", future_time);
    try testing.expect(success);
    try testing.expect(!store.is_expired("key1"));
    try testing.expect(store.get("key1") != null);
    try testing.expectEqual(future_time, store.get_ttl("key1").?);

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

test "Store counts keyspace hits and misses" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    try store.set("present", "v");
    _ = store.get("present");
    _ = store.get("missing");

    try testing.expectEqual(@as(u64, 1), store.counters.keyspace_hits);
    try testing.expectEqual(@as(u64, 1), store.counters.keyspace_misses);
}

test "Store counts a key found past its expiry as expired and missed" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    try store.set("stale", "v");
    _ = try store.expire("stale", clock.now().toMilliseconds() - 1);
    _ = store.get("stale");

    try testing.expectEqual(@as(u64, 1), store.counters.expired_keys);
    try testing.expectEqual(@as(u64, 1), store.counters.keyspace_misses);
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

    try store.set("str1", "hello");
    try store.set("str2", "world");
    try store.set_int("int1", 42);
    try store.set_int("int2", -100);

    const list = try store.create_list("mylist");
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item1") });
    try list.append(.{ .string = try testing.allocator.dupe(u8, "item2") });

    try testing.expectEqual(@as(u32, 5), store.size());
    try testing.expect(store.exists("str1"));
    try testing.expect(store.exists("str2"));
    try testing.expect(store.exists("int1"));
    try testing.expect(store.exists("int2"));
    try testing.expect(store.exists("mylist"));

    store.flush_db();

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

test "Store flush_db allows reuse after flush" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 4096 });
    defer store.deinit();

    try store.set("key1", "value1");
    try store.set_int("key2", 123);
    try testing.expectEqual(@as(u32, 2), store.size());

    store.flush_db();
    try testing.expectEqual(@as(u32, 0), store.size());

    try store.set("key3", "value3");
    try store.set_int("key4", 456);
    try testing.expectEqual(@as(u32, 2), store.size());

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

    store.maintenance();

    const capacity_after = store.capacity();
    const size_after = @as(usize, store.size());

    // Size should remain the same
    try testing.expectEqual(@as(usize, 500), size_after);

    // Capacity should be reduced.
    try testing.expect(capacity_after < capacity_before);

    i = 500;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        const result = store.get(key);
        try testing.expect(result != null);
        try testing.expectEqualStrings("value", result.?.value.short_string.as_slice());
    }
}

/// Every used slot must be reachable from its home slot without crossing an
/// empty slot; otherwise a lookup would stop at the gap.
fn expectProbeChainsIntact(store: *const Store) !void {
    const mask = store.slots.len - 1;
    for (store.slots, 0..) |s, i| {
        if (s.idx == empty_slot) continue;
        const home = @as(usize, s.hash) & mask;
        var j = home;
        while (j != i) : (j = (j + 1) & mask) {
            try testing.expect(store.slots[j].idx != empty_slot);
        }
    }
}

test "Store delete keeps probe chains contiguous" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    const key_count: usize = 500;
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    // Deleting every third key leaves gaps inside probe clusters.
    i = 0;
    while (i < key_count) : (i += 3) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try testing.expect(store.delete(key));
    }

    try expectProbeChainsIntact(&store);

    i = 0;
    while (i < key_count) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try testing.expectEqual(i % 3 != 0, store.get(key) != null);
    }

    // Re-inserting into the shifted clusters must still find the keys.
    i = 0;
    while (i < key_count) : (i += 3) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }
    try testing.expectEqual(@as(u32, @intCast(key_count)), store.size());
    try expectProbeChainsIntact(&store);
}

test "Store rename_key moves the entry between probe chains" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    try testing.expect(try store.rename_key("key7", "renamed"));
    try testing.expect(store.get("key7") == null);
    try testing.expectEqualStrings("value", store.get("renamed").?.value.short_string.as_slice());
    try testing.expectEqual(@as(u32, 200), store.size());
    try expectProbeChainsIntact(&store);

    // Renaming onto an existing key replaces it.
    try testing.expect(try store.rename_key("renamed", "key8"));
    try testing.expect(store.get("renamed") == null);
    try testing.expectEqualStrings("value", store.get("key8").?.value.short_string.as_slice());
    try testing.expectEqual(@as(u32, 199), store.size());
    try expectProbeChainsIntact(&store);

    try testing.expect(!try store.rename_key("missing", "nope"));
    try testing.expect(try store.rename_key("key8", "key8"));
}

test "Store maybe_maintenance() respects rate limiting" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    // Block the automatic maintenance calls inside delete() so this test can
    // deterministically exercise the explicit maybe_maintenance() call.
    store.last_maintenance_check = store.clock.now().toMilliseconds() + 60_000;

    // Delete enough keys that a rebuild can actually shrink the table.
    i = 0;
    while (i < 700) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    const capacity_before = store.capacity();

    store.last_maintenance_check = 0;
    const last_check_before = store.last_maintenance_check;

    store.maybe_maintenance();
    const capacity_after_first = store.capacity();
    const last_check_after_first = store.last_maintenance_check;

    // First call should trigger maintenance.
    try testing.expect(capacity_after_first < capacity_before);
    try testing.expect(last_check_after_first > last_check_before);

    // Immediately call again (within 50ms); it must be rate-limited.
    store.maybe_maintenance();
    const capacity_after_second = store.capacity();
    const last_check_after_second = store.last_maintenance_check;

    try testing.expectEqual(capacity_after_first, capacity_after_second);
    try testing.expectEqual(last_check_after_first, last_check_after_second);
}

test "Store maintenance() shrinks a half-empty table" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity_before = store.capacity();

    i = 0;
    while (i < 600) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    store.last_maintenance_check = 0;
    store.maintenance();

    try testing.expect(store.capacity() < capacity_before);
    try testing.expectEqual(@as(u32, 400), store.size());

    i = 600;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try testing.expect(store.get(key) != null);
    }
}

test "Store maintenance() keeps capacity while the table is not half empty" {
    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(testing.allocator, testing.io, &clock, .{ .initial_capacity = 16 });
    defer store.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        try store.set(key, "value");
    }

    const capacity_before = store.capacity();

    // 900 live entries in the same table still need the same slot count, so
    // maintenance must not rehash for nothing.
    i = 0;
    while (i < 100) : (i += 1) {
        const key = try testing.allocator.print("key{d}", .{i});
        defer testing.allocator.free(key);
        _ = store.delete(key);
    }

    store.last_maintenance_check = 0;
    store.maintenance();

    try testing.expectEqual(capacity_before, store.capacity());
    try testing.expectEqual(@as(u32, 900), store.size());
}

test "Store evict_one allkeys clock evicts the coldest key" {
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
    try testing.expectEqual(@as(u64, 1), store.counters.evicted_keys);
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

test "Store evict_one prefers an expired key over a live one" {
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
