# Store Cache Layout

How Zedis stores keys and values in memory, why the original layout thrashed the
CPU cache, and how the store was reworked to be cache-friendly.

---

## 1. Summary

The store's hash table was rewritten from `std.StringHashMapUnmanaged(*StoreEntry)`
(a pointer-based map) to a custom open-addressing table. Each slot stores a 32-bit
hash fingerprint and an index into a stable, growable array of **entry pointers**;
short keys (≤ 23 bytes) are stored **inline inside the entry**. A `GET` that
previously chased three scattered heap allocations (map bucket → entry → key) now
touches two structures: the contiguous slot array and the entry allocation, with the
key already inside the entry. The `entries[idx]` pointer hop remains; the indirection
that was removed is the per-probe key dereference.

Measured impact:

| Workload                        | Result                                    |
| ------------------------------- | ----------------------------------------- |
| Random `GET` over a large store | ~1.5x faster (working set exceeds L3)     |
| Skewed hot-key `GET`            | ~1.5x faster                              |
| `DEL`-heavy workloads           | ~2x faster (free-list reuse, no malloc)   |
| Small, cache-resident store     | ~parity (std `HashMap` is well optimized) |

The win is specifically for **large stores** — the realistic production case for a
Redis-compatible database — where the working set no longer fits in cache.

---

## 2. Background: CPU caches

### 2.1 You cannot "pin" keys to L1/L2/L3

A frequent question is: *"can I keep hot keys in L1/L2/L3 cache?"* The short answer
is no — not directly:

- L1/L2/L3 caches are **hardware-managed**. They are address-tagged with a
  hardware replacement policy (roughly LRU/PLRU per set). Software cannot place a
  specific key at a specific cache level.
- The CPU decides residency based on *which addresses* are accessed and *when*.
  The only influence software has is **where data lives in memory** and **how it is
  laid out**.

What software *can* do:

| Technique                            | Effect                                          |
| ------------------------------------ | ----------------------------------------------- |
| Compact, contiguous data layout      | Hot data shares cache lines; fewer misses       |
| Store fields used together, together | One load pulls its neighbors into the same line |
| Avoid pointer chasing                | Each chase is a likely cache miss               |
| Prefetch (`@prefetch`)               | Overlap latency of a known future access        |
| Huge pages                           | Reduce TLB misses (often mistaken for "cache")  |
| Intel CAT                            | Coarse L2/L3 way-partitioning (not per-key)     |

The rest of this document is about the first three: layout, field placement, and
reducing pointer chasing.

### 2.2 Cache lines

A cache line is 64 bytes on x86 and Apple Silicon. When any byte in a line is read,
the whole line is fetched. This means:

- Accessing 8 bytes costs one line (64 bytes) regardless.
- Two values that live in the same 64-byte region are effectively "free" to read
  once one of them is fetched.
- A pointer to a scattered heap allocation is, on first touch, a full cache miss.

Optimizing cache behavior is therefore about **co-locating** frequently-accessed
data in the same lines and **reducing the number of distinct lines touched**.

---

## 3. The problem: original layout

### 3.1 Data structures

```zig
// original
const EntryMap = std.StringHashMapUnmanaged(*StoreEntry);

const StoreEntry = struct {
    key: []const u8,        // -> separate heap allocation
    object: ZedisObject,    // 24 bytes (tag + payload)
    expires_at: ?i64,       // 16 bytes
    last_access: u64,       // 8 bytes
    prev_lru: ?*StoreEntry, // 4 x 8-byte pointers = 32 bytes
    next_lru: ?*StoreEntry,
    prev_volatile: ?*StoreEntry,
    next_volatile: ?*StoreEntry,
};                          // 96 bytes total (measured)
```

Measured sizes:

| Type          | Size | Notes                              |
| ------------- | ---- | ---------------------------------- |
| `ZedisValue`  | 24 B | tagged union (largest arm `[]u8`)  |
| `ZedisObject` | 24 B |                                    |
| `StoreEntry`  | 96 B | 1.5 cache lines of *metadata only* |

### 3.2 The `GET` path: three pointer chases

For a string key read, the code touched **three or four separate heap allocations**:

1. **Hash bucket** — `StringHashMapUnmanaged` stores a key slice + entry pointer
   per bucket (24 B). On each probe it compared keys by *dereferencing the stored
   key slice* (a heap pointer).
2. **Entry** — the bucket held `*StoreEntry`, a pointer to another allocation.
3. **Key bytes** — `entry.key` was a `dupe`'d heap string, dereferenced to compare.
4. **Value bytes** — for strings > 23 bytes, `object.value.string` was a fourth
   allocation (short strings were already inline via `ShortString`).

Each of those is a likely cache miss (and a TLB miss if it lands on a new page),
because nothing is contiguous with anything else.

The entry itself was 96 bytes of *metadata* (expiry, access stamp, four LRU
pointers) — not data — yet it was a separate allocation from the key and value.

---

## 4. Design goals

1. **Eliminate the key indirection** — store short keys inline in the entry.
2. **Eliminate per-probe key dereferences** — compare 4-byte hashes in a contiguous
   slot array, touching the entry only when the hash matches.
3. **Keep entry pointers stable** — entries stay individually allocated and never
   move, so `get()`, `get_list()`, etc. still return valid pointers and the existing
   LRU/volatile linked lists keep working.
4. **Preserve the public API** — callers (`commands/*`, `server`, `kv_allocator`,
   benchmarks, RDB) are unchanged apart from the additions listed in §8.
5. **Reuse deleted entries** — pool them on a free list instead of calling
   `malloc`/`free` under delete-heavy workloads.

---

## 5. The new design

### 5.1 Overview

```zig
const Slot = struct {
    hash: u32,   // 32-bit hash fingerprint
    idx:  u32,   // index into `entries` (or empty_slot / tomb_slot sentinel)
};               // 8 bytes, 8 slots per cache line

const StoreEntry = struct {
    key: []const u8,
    inline_key_data: [23]u8,     // key inline when len <= 23
    object: ZedisObject,
    expires_at: ?i64,
    last_access: u64,
    prev_lru: ?*StoreEntry,      // unchanged pointer-based LRU
    next_lru: ?*StoreEntry,
    prev_volatile: ?*StoreEntry,
    next_volatile: ?*StoreEntry,
    next_free: u32,              // free-list link
};

pub const Store = struct {
    slots: []Slot,           // open-addressing hash table (contiguous)
    entries: []*StoreEntry,  // stable pool of entry pointers
    count: usize,            // live entries
    free_head: u32,          // free-list head (index into entries)
    // ... LRU / clock / policy fields unchanged
};
```

Two parallel arrays replace the single pointer map:

- `slots` — the hash table. Probing reads 4-byte hashes from one contiguous array.
- `entries` — a growable array of pointers to individually allocated `StoreEntry`
  structs. The pointers are stable for the lifetime of the key; the array itself can
  be compacted, which rewrites each live slot's `idx`.

### 5.2 Hash-in-slot probing

**Probing** is the walk a hash table does when a key isn't at its first index:
because collisions happen, the lookup steps `i, i+1, i+2, …` until it finds the key
or an empty slot. On *every* probe it must answer: *"is the key in this slot my
key?"* The cost of that one question, repeated, is the whole story.

**The old map answered it expensively.** Each bucket stored the full key as a
`[]const u8` slice pointing into the heap. To compare, it followed that pointer to
the key's bytes — a random heap allocation, so **one cache miss per probe**, even
for slots that turned out to be the wrong key.

**The new table answers it with an integer compare.** Each slot stores a 32-bit
hash fingerprint next to the entry index:

```zig
const Slot = struct { hash: u32, idx: u32 };  // 8 bytes
```

Probing compares only `slot.hash == h`:

```zig
fn findSlot(self, h32, key) ?usize {
    var i = h32 & mask;
    var remaining = slots.len;
    while (remaining > 0) : (remaining -= 1) {
        const s = slots[i];
        if (s.idx == empty_slot) return null;                  // stop at empty
        if (s.idx != tomb_slot and s.hash == h32) {            // hash match only
            if (std.mem.eql(u8, entries[s.idx].key, key)) return i; // rare: real compare
        }
        i = (i + 1) & mask;
    }
    return null;
}
```

No pointer or heap access on a non-matching probe (the rare hash match still
dereferences the entry to compare the full key). The `slots` array is contiguous, and
8 slots fit in one 64-byte cache line — so the first probe fetches a line and the next
~7 probes read memory already in cache.

Concretely, a lookup that probes 4 slots:

```
OLD:  probe0 -> follow key ptr -> MISS (heap key A)
      probe1 -> follow key ptr -> MISS (heap key B)
      probe2 -> follow key ptr -> MISS (heap key C)
      probe3 -> EMPTY                          = 3 cache misses

NEW:  [h0][h1][h2][h3]  <- one contiguous cache line
      compare hashes 0..3 (all cached) -> EMPTY = 1 line fetch
```

For a *found* key, the entry (and its key) is touched **once**, on the hash match,
instead of on every probe. That's the win: the hash fingerprint lives *in the slot*,
so probing never leaves the slot array.

### 5.3 Inline keys

Keys of ≤ 23 bytes are stored directly in `StoreEntry.inline_key_data`:

```zig
fn setEntryKey(self, entry, key) !void {
    if (key.len <= 23) {
        @memcpy(entry.inline_key_data[0..key.len], key);
        entry.key = entry.inline_key_data[0..key.len];   // self-referential slice
    } else {
        entry.key = try self.allocator.dupe(u8, key);     // long keys still heap
    }
}
```

Freeing is keyed off length: `free_entry_contents` only frees `entry.key` when
`key.len > 23` (inline keys live inside the entry, freed with it).

### 5.4 Stable entry pool + free list

`entries` is a growable array of `*StoreEntry`. Because each entry is
heap-allocated once and never moved, the existing `?*StoreEntry` LRU pointers and
all public methods that return entry pointers stay valid unchanged.

Deleted entries are not `destroy`ed immediately — they are chained onto a free list
via the `next_free` index field and reused by the next insert. This avoids
`malloc`/`free` churn under delete-heavy workloads (the source of the `DEL` speedup):

```zig
fn allocEntry(self) !struct { idx: u32, entry: *StoreEntry } {
    if (self.free_head != no_entry) {
        const idx = self.free_head;
        const entry = self.entries[idx];
        self.free_head = entry.next_free;      // pop from free list
        return .{ .idx = idx, .entry = entry };
    }
    // ... else allocate a fresh entry and append to entries
}
```

The pool is not permanent: `Store.reclaim_memory()` destroys pooled entries and
compacts `entries`/`slots` when the KV allocator cannot meet `maxmemory` by
eviction alone. It only runs at a command boundary, when no handler holds pointers
into the store.

### 5.5 Growth and shrinking

`rebuildSlots(min_capacity)` allocates a power-of-two slot array and re-probes every
live slot into it using the hash already cached in the slot (skipping tombstones).
Both growing the table and rebuilding it clear tombstones.

- `maybe_resize` (before insert): grows at 80% load factor.
- `maybe_maintenance` (after deletes): rate-limited to once every 50 ms; calls
  `maintenance`, which rebuilds when waste > 50% or tombstones exceed 25%.
- `reclaim_memory` (memory pressure): destroys pooled entries and shrinks
  `entries`/`slots` toward the live count. It is not periodic — it only runs when
  eviction cannot satisfy the KV budget.

### 5.6 Iteration

Because the map is now custom, the store exposes an explicit iterator so consumers
don't reach into internals:

```zig
pub const EntryView = struct { key: []const u8, object: *const ZedisObject, expires_at: ?i64 };
pub const Iterator = struct { /* walks slots, skipping empty_slot/tomb_slot */ };
pub fn iterator(self: *const Store) Iterator;
```

`src/persistence/zdb.zig` (RDB persistence) is the one external consumer and was
migrated to it.

---

## 6. Data structure sizes (measured)

| Type            | Old (pointer)  | New (inline)   |
| --------------- | -------------- | -------------- |
| `StoreEntry`    | 96 B           | 128 B          |
| Key storage     | +32 B alloc    | inline (≤23 B) |
| Map bucket/slot | 24 B (key+ptr) | 8 B (hash+idx) |

The entry struct itself grew (the inline key buffer pushed it from 96 → 128 bytes,
i.e. 2 cache lines), but the **total bytes per short-key entry dropped** because the
key allocation and the map's per-bucket key-slice copy are gone. More importantly,
the number of *distinct memory locations touched* per lookup dropped from 3–4 to 2.

For the prototype's minimal entry (no expiry/LRU):

| Prototype type | Size                       |
| -------------- | -------------------------- |
| `PointerEntry` | 56 B (entry + key + value) |
| `InlineEntry`  | 64 B (single cache line)   |

---

## 7. Prototype and measurements (historical)

Before touching the real store, a standalone prototype benchmark compared the two
designs head-to-head with a 1,000,000-key working set (≈ 64–150 MB, deliberately
larger than L3) to expose memory-latency behavior. The prototype was a local,
uncommitted benchmark and is no longer part of the tree; the numbers below are
historical.

Representative results (ReleaseFast, Apple Silicon):

| Operation            | PointerStore | InlineStore | Speedup |
| -------------------- | ------------ | ----------- | ------- |
| SET (populate)       | ~43 ns/op    | ~41 ns/op   | ~1.0x   |
| GET (sequential)     | ~31 ns/op    | ~38 ns/op   | ~0.8x   |
| GET (uniform random) | ~60 ns/op    | ~39 ns/op   | ~1.5x   |
| GET (skewed hot-set) | ~27 ns/op    | ~18 ns/op   | ~1.5x   |

Key observations:

- **Random access** (the memory-latency-bound case) is where the layout wins — the
  inline store touches fewer cache lines per lookup.
- **Sequential access** is prefetch-friendly; the hardware predictor hides most of
  the difference, so it's roughly parity.
- **Insert** is parity — the general allocator's small-`malloc` is already fast.

> Note: absolute numbers vary between runs (thermal state, load). The *ratios*
> are the signal: random `GET` is consistently ~1.5x faster with inline layout.

---

## 8. Implementation in `src/storage/store.zig`

Public API (`set`, `get`, `put_object`, `delete`, `exists`, `get_type`, `keys`,
`get_list`, `create_list`, `expire`, `persist`, `rename_key`, `evict_one`,
`maintenance`, etc.) is unchanged apart from the additions below. What changed:

**Added**

- `Slot`, `empty_slot` / `tomb_slot` / `no_entry` sentinels
- `Store` fields: `slots`, `entries`, `count`, `free_head`
- `keyHash`, `findSlot`, `findInsertSlot`, `rebuildSlots`, `allocEntry`, `setEntryKey`
- `iterator()` + `EntryView` / `Iterator`
- `capacity()` (replaces test access to the old `.map.capacity()`)
- `reclaim_memory()` (added later) — destroys pooled entries and compacts
  `entries`/`slots` when the KV budget cannot be met by eviction

**Rewritten**

- `init` / `deinit`, `put_object`, `delete`, `resolve_entry`
- `keys`, `random_key`, `flush_db`
- `expire`, `is_expired`, `get_ttl`, `persist`, `rename_key`
- `maintenance`, `maybe_maintenance`

**Unchanged**

- `ZedisObject`, `ValueType`, value semantics
- `clone_owned_object`, `free_object_value`
- All LRU / volatile-LRU list logic (`detach_lru`, `attach_lru_head`,
  `sample_global_victim`, `evict_expired_volatile`, …) — still pointer-based
- Expiry semantics and eviction sampling

---

## 9. Correctness: the tombstone infinite loop

The first version of `findSlot` used `while (true)` and returned only on the
`EMPTY` sentinel. Under delete-heavy workloads, deletions leave **tombstone** slots
(occupied, but pointing to a freed entry). When a table filled with tombstones and
no `EMPTY` slot remained, `findSlot` skipped tombstones forever and **hung**.

This was exposed by the `DEL` benchmark in `zig build bench:micro` (each iteration
does `SET` then `DEL`, rapidly accumulating tombstones).

Two fixes:

1. **Bound the probe** — `findSlot` now scans at most `slots.len` positions and
   returns `null` if it wraps around, guaranteeing termination:

   ```zig
   var remaining: usize = self.slots.len;
   while (remaining > 0) : (remaining -= 1) { ... }
   return null;
   ```

2. **Clear tombstones when empty** — `maintenance` previously early-returned when
   `count == 0`, leaving tombstones behind forever. It now rebuilds to the minimum
   table when `count == 0` and there are pending deletions.

`findInsertSlot` was already safe: the store grows at 80% load, so there is always
an `EMPTY` or `TOMB` slot to reuse.

---

## 10. Stack overflow analysis

No. The inline store cannot overflow the stack:

1. **No recursion.** All collection traversal is iterative `while` loops:
   - hash probing (`findSlot`, `findInsertSlot`) is a flat loop;
   - LRU / volatile lists are walked with `while` over `prev`/`next` pointers
     (`detach_lru`, `sample_global_victim`) — not recursive, so a million-entry
     list is fine;
   - `deinit` / `flush_db` iterate `slots` and `entries` in `for` loops.
2. **No large stack buffers.** All dynamic storage (`slots`, `entries`, keys, the
   `rebuildSlots` temporary) is heap-allocated via `self.allocator`. Per-call stack
   usage is a few small locals (an index, a `Slot`, an `EntryView`).

The only potential recursion is inside the *value* types' `deinit` (e.g. a linked
`ZedisList`). That is pre-existing and untouched — `free_object_value` is identical
to the original.

---

## 11. Performance evaluation (honest comparison)

Two benchmarks measure two different regimes, and they disagree — correctly.

### 11.1 `zig build bench:micro` (10k keys, cache-resident)

The micro-benchmarks use a ~10,000-key working set that fits entirely in L3. In this
regime the mature, heavily-optimized `std.HashMap` is hard to beat, and the custom
table carries some overhead (bounded-probe counter, the `slots` → `entries` hop):

| Metric             | Pointer (old)  | Inline (new)    |
| ------------------ | -------------- | --------------- |
| Store.get (cached) | 31.4M ops/s    | 29.3M ops/s     |
| Store.set          | 28.1M ops/s    | 25.8M ops/s     |
| Store.exists       | 35.2M ops/s    | 30.9M ops/s     |
| Store.delete       | 30.7M ops/s    | 34.5M ops/s     |
| **Command: DEL**   | **5.9M ops/s** | **12.4M ops/s** |

The one clear win at this size is **`DEL`**: the free-list reuse avoids the
`malloc`/`free` churn that the old store paid on every delete (~2.1x).

### 11.2 Prototype (1M keys, exceeds L3)

The large-working-set prototype (section 7) is where the inline layout pays off:
~1.5x on random `GET`, where every lookup is memory-latency-bound.

### 11.3 What this means

The cache-friendly layout is **not** a universal speedup. It is a bet that the
realistic production case — a store with millions of keys that does not fit in
cache — is dominated by memory latency, not by raw hash-map micro-ops. For that
case, touching fewer cache lines per lookup wins. For a tiny cache-resident store,
the standard library map is fine and marginally faster.

---

## 12. Trade-offs and limitations

- **Entry struct grew** from 96 → 128 bytes (the inline key buffer). The win is in
  *locality*, not raw struct size: the key and value now share lines with the entry.
- **Two-array indirection**: `slots` → `entries` adds one hop vs. a single inline
  value array. This is the price of keeping entry pointers stable (so the LRU lists
  and `get()`'s returned pointers don't break).
- **Long keys/values** (> 23 bytes) still heap-allocate; they get no inline benefit.
- **Small stores** see little or no gain (section 11.1).
- **32-bit hashes** with full key compare on match — collision cost is one extra
  entry read, not a correctness issue.

---

## 13. Related files

- `src/storage/store.zig` — the store implementation
- `src/persistence/zdb.zig` — RDB persistence, migrated to `Store.iterator()`
- `docs/memory-architecture.md` — allocation domains and memory budget
- `docs/server-architecture.md` — server structure

---

## 14. Future work

- **Pack `expires_at`**: `?i64` is 16 bytes (tag + value). An `i64` sentinel (`0` =
  no expiry) would save 8 bytes per entry.
- **Inline long-key threshold tuning**: the 23-byte limit mirrors `ShortString`;
  could be a separate tunable.
- **Index-based LRU**: replace the four `?*StoreEntry` LRU pointers with `u32`
  indices. Only worthwhile if entries move into a contiguous value slab (currently
  they stay heap-allocated for pointer stability).
- **Tombstone rehash tuning**: rehash more eagerly under sustained delete loads to
  keep `findSlot` probes short without relying on the 50 ms rate limiter.
