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

Reproducible impact (`scripts/hashmap-ab.sh`, 1M keys, 128 B values):

| Workload                            | Result                                          |
| ----------------------------------- | ----------------------------------------------- |
| Sequential `GET` (insertion order)  | 1.6-1.8x faster                                 |
| Uniform-random `GET`                | ~5% slower (extra `entries[idx]` hop, see §11)  |
| Hot-set `GET` (1% of keys)          | parity                                          |
| Cache-resident `GET` (10k keys)     | parity to ~10% faster                           |
| `SET`+`DEL` churn                   | 1.2-1.6x faster (free-list reuse, no malloc)    |
| Bulk `DEL`, 1M keys                 | ~1.3x faster                                    |
| Bulk `DEL`, 10k keys                | slower than a cache-hot `free()` (see §12)      |

The layout pays off for sequential and delete-churn traffic. Uniform-random access
does not benefit: it touches fewer cache lines but serializes `slots -> entries ->
entry`. The original claim that this design is ~1.5x faster on random `GET` did not
reproduce and has been removed.

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
    idx:  u32,   // index into `entries` (or the empty_slot sentinel)
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
        if (s.hash == h32) {                                   // hash match only
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
live slot into it using the hash already cached in the slot.

- `maybe_resize` (before insert): grows at 80% load factor.
- Deletes leave no tombstones: `shiftBackward` moves the rest of the probe cluster
  down (see §9), so lookups still stop at the first empty slot.
- `maybe_maintenance` (after deletes): runs at most once every 50 ms, and only when
  a rebuild can actually shrink the table (`shrinkTarget(count) < slots.len`).
- `reclaim_memory` (memory pressure): destroys pooled entries and shrinks
  `entries`/`slots` toward the live count. It is not periodic — it only runs when
  eviction cannot satisfy the KV budget.

### 5.6 Iteration

Because the map is now custom, the store exposes an explicit iterator so consumers
don't reach into internals:

```zig
pub const EntryView = struct { key: []const u8, object: *const ZedisObject, expires_at: ?i64 };
pub const Iterator = struct { /* walks slots, skipping empty_slot */ };
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

---

## 7. Measurements

`scripts/hashmap-ab.sh` builds a standalone A/B harness with the same entry sizes
(96 B pointer map vs 128 B inline map) and the same 80% load factor, then reports
wall clock and, when `perf` is available, `perf stat` counters. Representative
results (1M keys, 128 B values, ReleaseFast):

| Operation                        | ptr map | inline table | ratio            |
| -------------------------------- | ------- | ------------ | ---------------- |
| GET sequential (insertion order) | 59.7 ns | 36.7 ns      | **1.6x faster**  |
| GET uniform random               | 162 ns  | 174 ns       | ~7% slower       |
| GET hot set (1% of keys)         | 57.5 ns | 65.4 ns      | ~14% slower      |
| GET cache-resident (10k keys)    | 15.0 ns | 14.8 ns      | parity           |
| SET+DEL churn (1M)               | 115 ns  | 71 ns        | **1.6x faster**  |
| SET+DEL churn (10k)              | 39.6 ns | 35.4 ns      | 1.1x faster      |
| DEL-only (1M)                    | 60.1 ns | 47.3 ns      | **1.3x faster**  |
| DEL-only (10k)                   | 15.4 ns | 30.3 ns      | 2x slower        |

The pattern is the design bet, not a universal speedup: insertion-order access
streams the `entries` array and the inline keys, while random access pays for the
serialized `slots -> entries -> *StoreEntry` chain. Delete churn wins on the free
list; a bulk delete of a small, cache-resident table loses because shifting the
cluster costs more than a cache-hot `free()`.

These numbers replace an earlier prototype table that claimed ~1.5x on random GET
and ~0.8x on sequential GET; neither reproduced on x86-64 Linux or Apple Silicon.

---

## 8. Implementation in `src/storage/store.zig`

Public API (`set`, `get`, `put_object`, `delete`, `exists`, `get_type`, `keys`,
`get_list`, `create_list`, `expire`, `persist`, `rename_key`, `evict_one`,
`maintenance`, etc.) is unchanged apart from the additions below. What changed:

**Added**

- `Slot`, `empty_slot` / `no_entry` sentinels
- `Store` fields: `slots`, `entries`, `count`, `free_head`
- `keyHash`, `findSlot`, `findInsertSlot`, `rebuildSlots`, `allocEntry`, `setEntryKey`
- `shiftBackward` (tombstone-free deletion)
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

## 9. Deletion without tombstones

The first version of the table used tombstones: `delete` marked the slot
`tomb_slot` and relied on periodic rehashing to clear them. That had two failure
modes:

1. **Probe degradation** — after a large delete burst the table was mostly
   tombstones, so every lookup walked a long cluster.
2. **An unbounded probe loop** — `findSlot` originally looped until it saw
   `empty_slot`; a table full of tombstones with no empty slot hung the server.
   The probe is still bounded by `slots.len` as a safety net.

`delete` now calls `shiftBackward`, which removes the hole and shifts the rest of
the cluster down whenever the hole is at or after the moved entry's home slot in
probe order:

```zig
fn shiftBackward(self: *Store, hole: usize) void {
    ...
    if (((j -% home) & mask) >= ((j -% h) & mask)) { ... }
}
```

Every live entry therefore stays on a contiguous run from its home slot to its
current slot, which is exactly the invariant `findSlot` relies on. There are no
tombstones, no tombstone counter, and no maintenance schedule required for
correctness. The price is that `delete` is O(cluster length) instead of O(1).

Tests cover the invariant directly (`expectProbeChainsIntact`) and delete/reinsert
cycles on a clustered table.

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

## 11. Performance evaluation

Two regimes, two answers. Both are reproducible with `scripts/hashmap-ab.sh`.

### 11.1 Cache-resident (10k keys)

`std.HashMap` is hard to beat when everything fits in L2/L3: measured parity to
~10% in favor of the inline table, depending on run. The extra `entries` hop is
not compensated by locality at this size.

### 11.2 Large working set (1M keys, ~150 MB)

This is where the layout pays:

- **Sequential `GET`: 1.6-1.8x faster.** `perf` reports 1.5 vs 3.7 cache
  misses/op and 152 vs 276 cycles/op; the inline key removes a dereference on
  every compare.
- **Uniform-random `GET`: ~5% slower.** `perf` reports ~20% fewer cache misses
  but slightly more cycles and worse CPI: the `slots -> entries -> *Entry` chain
  serializes dependent loads.
- **SET+DEL churn: 1.2-1.6x faster.** 16% fewer instructions because the free
  list avoids `malloc`/`free`/`dupe` per cycle.
- **Bulk `DEL`:** ~1.3x faster at 1M keys; slower at 10k, where shifting the
  cluster costs more than a cache-hot `free()`.

### 11.3 What this means

The cache-friendly layout is a bet on sequential and churn-heavy traffic. It is
not a universal speedup, and it does not help uniform-random reads. For a small
cache-resident store, `std.HashMap` is fine and marginally faster.

## 12. Trade-offs and limitations

- **Entry struct grew** from 96 → 128 bytes (the inline key buffer). The win is in
  *locality*, not raw struct size: the key and value now share lines with the entry.
- **Two-array indirection**: `slots` → `entries` adds one hop vs. a single inline
  value array. This is the price of keeping entry pointers stable (so the LRU lists
  and `get()`'s returned pointers don't break).
- **Long keys/values** (> 23 bytes) still heap-allocate; they get no inline benefit.
- **Small stores** see little or no gain (§11.1).
- **Deletion is O(probe cluster)**: shifting keeps lookups contiguous, but a bulk
  delete of a small dense table is slower than a tombstone or a cache-hot
  `free()`. Interleaved deletes (eviction, expiry) shift only a few slots.
- **32-bit hashes** with full key compare on match — collision cost is one extra
  entry read, not a correctness issue.

---

## 13. Related files

- `src/storage/store.zig` — the store implementation
- `src/persistence/zdb.zig` — RDB persistence, migrated to `Store.iterator()`
- `scripts/hashmap-ab.sh` — reproducible A/B harness (ptr map vs inline table)
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
- **Re-measure after layout changes**: `scripts/hashmap-ab.sh` covers GET, DEL and
  churn at 10k and 1M keys. Keep this document's numbers tied to a run.
