const std = @import("std");
const testing = std.testing;
const Config = @import("../app/config.zig");
const Store = @import("store.zig").Store;
const Clock = @import("../app/clock.zig");
const mem = std.mem;

const KeyValueAllocator = @This();

base_allocator: mem.Allocator,
memory_used: std.atomic.Value(usize),
memory_budget: usize,
eviction_policy: Config.EvictionPolicy,
store: ?*Store = null,
/// Set while a command is executing. Like Redis' `maxmemory`, the budget is
/// soft inside a command: allocations may push usage past it, and eviction is
/// deferred to the next command boundary (`enforce_budget`). This keeps
/// eviction from running while a handler holds pointers into the store.
in_command: bool = false,

pub fn init(base_allocator: mem.Allocator, budget: usize, eviction_policy: Config.EvictionPolicy) !KeyValueAllocator {
    return .{
        .base_allocator = base_allocator,
        .memory_used = .init(0),
        .memory_budget = budget,
        .eviction_policy = eviction_policy,
        .store = null,
        .in_command = false,
    };
}

/// Marks the start of command execution. Allocations from here until
/// `end_command` are not budget-checked; Redis behaves the same way, allowing
/// a command to overshoot `maxmemory` and reclaiming on the next command.
pub fn begin_command(self: *KeyValueAllocator) void {
    self.in_command = true;
}

pub fn end_command(self: *KeyValueAllocator) void {
    self.in_command = false;
}

/// Evicts entries until usage is within budget, as Redis' `performEvictions`
/// does before every command. Returns false when usage is still over budget
/// (only possible under `noeviction`, or when nothing can be evicted).
pub fn enforce_budget(self: *KeyValueAllocator) bool {
    const budget = self.memory_budget;
    // `0` means no limit, like `maxmemory 0` in Redis.
    if (budget == 0) return true;

    const store = self.store orelse return self.memory_used.load(.acquire) <= budget;

    while (self.memory_used.load(.acquire) > budget) {
        if (self.eviction_policy != .noeviction and store.evict_one(self.eviction_policy)) {
            continue;
        }

        // Eviction can't help (no evictable keys, or noeviction). Reclaim pool
        // memory that isn't holding live data: deleted entries stay pooled for
        // reuse, and arrays stay at their high-water mark, so without this a
        // server that once held many keys could never shrink to a lower limit.
        const was_in_command = self.in_command;
        self.in_command = true; // shrinking allocates; do not recurse into eviction
        const reclaimed = store.reclaim_memory();
        self.in_command = was_in_command;
        if (!reclaimed) return false;
    }

    return true;
}

pub fn attach_store(self: *KeyValueAllocator, store: *Store) void {
    self.store = store;
}

pub fn deinit(_: *KeyValueAllocator) void {}

pub fn allocator(self: *KeyValueAllocator) mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = mem.Allocator.noRemap,
        },
    };
}

fn ensure_budget(self: *KeyValueAllocator, additional_bytes: usize) bool {
    // Inside a command the budget is soft (see `begin_command`); eviction
    // happens at the next command boundary instead.
    if (self.in_command) return true;

    // `0` means no limit, like `maxmemory 0` in Redis.
    if (self.memory_budget == 0) return true;

    if (additional_bytes > self.memory_budget) return false;

    while (self.memory_used.load(.acquire) > self.memory_budget - additional_bytes) {
        if (self.eviction_policy == .noeviction) return false;

        const store = self.store orelse {
            std.debug.assert(false);
            return false;
        };
        if (!store.evict_one(self.eviction_policy)) return false;
    }

    return true;
}

fn alloc(ctx: *anyopaque, len: usize, ptr_align: mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *KeyValueAllocator = @ptrCast(@alignCast(ctx));

    if (!self.ensure_budget(len)) return null;

    const ptr = self.base_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
    _ = self.memory_used.fetchAdd(len, .monotonic);
    return ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *KeyValueAllocator = @ptrCast(@alignCast(ctx));

    if (new_len > buf.len) {
        if (!self.ensure_budget(new_len - buf.len)) return false;
    }

    if (!self.base_allocator.rawResize(buf, buf_align, new_len, ret_addr)) return false;

    if (new_len > buf.len) {
        _ = self.memory_used.fetchAdd(new_len - buf.len, .monotonic);
    } else {
        _ = self.memory_used.fetchSub(buf.len - new_len, .monotonic);
    }
    return true;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: mem.Alignment, ret_addr: usize) void {
    const self: *KeyValueAllocator = @ptrCast(@alignCast(ctx));

    self.base_allocator.rawFree(buf, buf_align, ret_addr);
    _ = self.memory_used.fetchSub(buf.len, .monotonic);
}

pub fn get_memory_usage(self: *KeyValueAllocator) usize {
    return self.memory_used.load(.acquire);
}

pub fn get_memory_budget(self: *KeyValueAllocator) usize {
    return self.memory_budget;
}

test "KeyValueAllocator tracks alloc free and resize" {
    var kv = try KeyValueAllocator.init(testing.allocator, 1024, .noeviction);
    defer kv.deinit();

    const kv_alloc = kv.allocator();

    var slice = try kv_alloc.alloc(u8, 128);
    defer kv_alloc.free(slice);

    try testing.expectEqual(@as(usize, 128), kv.get_memory_usage());

    slice = try kv_alloc.realloc(slice, 256);
    try testing.expectEqual(@as(usize, 256), kv.get_memory_usage());

    slice = try kv_alloc.realloc(slice, 64);
    try testing.expectEqual(@as(usize, 64), kv.get_memory_usage());
}

test "KeyValueAllocator returns out of memory without eviction" {
    var kv = try KeyValueAllocator.init(testing.allocator, 2048, .noeviction);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 4,
        .eviction_policy = .noeviction,
    });
    defer store.deinit();

    kv.attach_store(&store);

    var value: [256]u8 = undefined;
    @memset(&value, 'x');

    var key_buf: [32]u8 = undefined;
    var saw_oom = false;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        store.set(key, value[0..]) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            saw_oom = true;
            break;
        };
    }

    try testing.expect(saw_oom);
    try testing.expect(kv.get_memory_usage() <= kv.get_memory_budget());
}

test "KeyValueAllocator evicts under allkeys_lru pressure" {
    var kv = try KeyValueAllocator.init(testing.allocator, 4096, .allkeys_lru);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 4,
        .eviction_policy = .allkeys_lru,
        .maxmemory_samples = 8,
    });
    defer store.deinit();

    kv.attach_store(&store);

    var value: [256]u8 = undefined;
    @memset(&value, 'y');

    var key_buf: [32]u8 = undefined;
    var last_key: [32]u8 = undefined;
    var last_key_len: usize = 0;

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        @memcpy(last_key[0..key.len], key);
        last_key_len = key.len;
        try store.set(key, value[0..]);
    }

    try testing.expect(kv.get_memory_usage() <= kv.get_memory_budget());
    try testing.expect(store.size() < 64);
    try testing.expect(store.get(last_key[0..last_key_len]) != null);
    try testing.expect(store.get("key-0") == null);
}

test "KeyValueAllocator survives repeated budgeted overwrite pressure" {
    const key_count = 256;
    const key_len = "evict-key:0000".len;
    const value_len = 1024;

    var kv = try KeyValueAllocator.init(testing.allocator, 288 * 1024, .allkeys_lru);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = key_count,
        .eviction_policy = .allkeys_lru,
        .maxmemory_samples = 5,
    });
    defer store.deinit();

    kv.attach_store(&store);

    var keys: [key_count][32]u8 = undefined;
    var values: [key_count][value_len]u8 = undefined;

    for (&keys, 0..) |*key_buf, i| {
        _ = try std.fmt.bufPrint(key_buf, "evict-key:{d:0>4}", .{i});
    }

    for (&values, 0..) |*value_buf, i| {
        @memset(value_buf, @as(u8, @truncate(i)));
    }

    var i: usize = 0;
    while (i < 60_000) : (i += 1) {
        const idx = @mod(i, key_count);
        const read_idx = @mod(i / 2, key_count);

        const key = keys[idx][0..key_len];
        const value = values[idx][0..];
        try store.set(key, value);

        const read_key = keys[read_idx][0..key_len];
        _ = store.get(read_key);
    }

    try testing.expect(kv.get_memory_usage() <= kv.get_memory_budget());
}

test "KeyValueAllocator allows command overshoot and enforces at boundary" {
    const budget = 4096;

    var kv = try KeyValueAllocator.init(testing.allocator, budget, .allkeys_lru);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 4,
        .eviction_policy = .allkeys_lru,
    });
    defer store.deinit();
    kv.attach_store(&store);

    var value: [1024]u8 = undefined;
    @memset(&value, 'z');

    // Inside a command the budget is soft, like Redis' maxmemory.
    kv.begin_command();
    for (0..8) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        try store.set(key, value[0..]);
    }
    kv.end_command();

    try testing.expect(kv.get_memory_usage() > budget);
    // The next command boundary evicts back down to the budget.
    try testing.expect(kv.enforce_budget());
    try testing.expect(kv.get_memory_usage() <= budget);
}

test "KeyValueAllocator noeviction cannot enforce an exceeded budget" {
    var kv = try KeyValueAllocator.init(testing.allocator, 4096, .noeviction);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 4,
        .eviction_policy = .noeviction,
    });
    defer store.deinit();
    kv.attach_store(&store);

    var value: [1024]u8 = undefined;
    @memset(&value, 'n');

    kv.begin_command();
    for (0..8) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        try store.set(key, value[0..]);
    }
    kv.end_command();

    try testing.expect(kv.get_memory_usage() > 4096);
    try testing.expect(!kv.enforce_budget());
    // Redis keeps reads and memory-freeing commands available.
    try testing.expect(store.get("key-0") != null);
    const before = kv.get_memory_usage();
    try testing.expect(store.delete("key-0"));
    try testing.expect(kv.get_memory_usage() < before);
}

test "KeyValueAllocator reclaims the entry pool when the budget shrinks" {
    var kv = try KeyValueAllocator.init(testing.allocator, 1024 * 1024, .allkeys_lru);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 64,
        .eviction_policy = .allkeys_lru,
    });
    defer store.deinit();
    kv.attach_store(&store);

    var value: [512]u8 = undefined;
    @memset(&value, 'p');

    kv.begin_command();
    for (0..3000) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        try store.set(key, value[0..]);
    }
    kv.end_command();
    try testing.expect(kv.get_memory_usage() > 1024 * 1024);

    // Like CONFIG SET maxmemory, far below the high-water entry pool.
    kv.memory_budget = 64 * 1024;
    try testing.expect(kv.enforce_budget());
    try testing.expect(kv.get_memory_usage() <= 64 * 1024);

    // The store is writable again at the new limit.
    try store.set("probe", "1");
    try testing.expect(store.get("probe") != null);
}

test "KeyValueAllocator reclaims pooled entries under noeviction" {
    var kv = try KeyValueAllocator.init(testing.allocator, 1024 * 1024, .noeviction);
    defer kv.deinit();

    var clock = Clock.init(testing.io, 0);
    var store = try Store.init(kv.allocator(), testing.io, &clock, .{
        .initial_capacity = 64,
        .eviction_policy = .noeviction,
    });
    defer store.deinit();
    kv.attach_store(&store);

    var value: [512]u8 = undefined;
    @memset(&value, 'q');

    kv.begin_command();
    for (0..3000) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        try store.set(key, value[0..]);
    }
    for (0..3000) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        _ = store.delete(key);
    }
    kv.end_command();

    // Deleted entries are pooled, so usage stays high until reclaimed.
    try testing.expect(kv.get_memory_usage() > 64 * 1024);

    kv.memory_budget = 64 * 1024;
    try testing.expect(kv.enforce_budget());
    try testing.expect(kv.get_memory_usage() <= 64 * 1024);
}

test "KeyValueAllocator treats a zero budget as unlimited" {
    var kv = try KeyValueAllocator.init(testing.allocator, 0, .noeviction);
    defer kv.deinit();

    const kv_alloc = kv.allocator();
    const buf = try kv_alloc.alloc(u8, 1024 * 1024);
    defer kv_alloc.free(buf);

    try testing.expectEqual(@as(usize, 1024 * 1024), kv.get_memory_usage());
    try testing.expect(kv.enforce_budget());
}

test "KeyValueAllocator works with smp allocator parent" {
    const base_allocator = std.heap.smp_allocator;

    var kv = try KeyValueAllocator.init(base_allocator, 288 * 1024, .allkeys_lru);
    defer kv.deinit();

    const io = testing.io;
    var clock = Clock.init(io, 0);
    var store = try Store.init(kv.allocator(), io, &clock, .{
        .initial_capacity = 256,
        .eviction_policy = .allkeys_lru,
        .maxmemory_samples = 5,
    });
    defer store.deinit();

    kv.attach_store(&store);

    var value: [1024]u8 = undefined;
    @memset(&value, 7);

    try store.set("evict-key:0000", value[0..]);
    try std.testing.expect(store.get("evict-key:0000") != null);
}
