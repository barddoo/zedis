---
title: "Memory architecture"
description: "Allocation domains, the KV budget and eviction, per-client parse arenas, the AOF writer thread and the disk tier."
---

Zedis uses multiple allocation domains to separate concerns: budgeted store data,
long-lived server structures, and per-command parsing.

## Allocation Domains

Three distinct allocation domains:

| Domain                 | Backing                                       | Lifetime        | Budgeted |
| ---------------------- | --------------------------------------------- | --------------- | -------- |
| `base_allocator`       | `std.process.Init.gpa` (see below)            | Server lifetime | No       |
| `kv_allocator`         | `KeyValueAllocator` wrapping `base_allocator` | Server lifetime | Yes      |
| Per-client parse arena | `ArenaAllocator` on `base_allocator`          | Per-command     | No       |

## Base Allocator

`init.gpa` is Zig's process allocator, passed from `main` into
`Server.init_with_config()`. Zig's start code installs `std.heap.SafeAllocator`
(page-backed) in Debug/Safe builds, and `c_allocator` or `smp_allocator` in
optimized builds; it is not a `GeneralPurposeAllocator`. It is used for
general-purpose server allocations not charged against the KV memory budget:

- Server metadata and config-owned strings
- `client_slots` array (fixed pool, allocated once)
- Command registry lifetime storage (`StringHashMap` keys/values)
- Pub/sub channel names and subscriber arrays (dynamic, grow/shrink with subscriptions)
- AOF/RDB loader allocations during startup
- AOF write queue (grows with unwritten commands) and file handles
- Per-command response `StackWriter` overflow allocations (when response exceeds 16KB)
- Mailbox `MessageNode` allocations (pub/sub delivery)
- Miscellaneous transient allocations

## KV Allocator

`KeyValueAllocator` wraps `base_allocator` with a custom vtable to enforce
`kv_memory_budget`. Inside a container the default is 80% of the cgroup memory
limit minus the fixed pool, with a 64 MB floor. Outside containers it is a
fixed 256 MB, and the server warns so the operator can size it. An explicit
`maxmemory`/`kv-memory-budget` disables sizing; `0` means unlimited, like
`maxmemory 0`. A missing `/proc/self/cgroup` (or a non-Linux host) falls back to
the 256 MB host budget; if the cgroup files exist but cannot be read, the server
refuses to start rather than guessing.
Every allocation, resize, and free adjusts an atomic `memory_used` counter.

The budget is applied the way Redis applies `maxmemory`:

- **Before every command**, `Server.memory_gate()` calls
  `KeyValueAllocator.enforce_budget()`, which evicts entries until usage is
  within budget (`allkeys_lru` / `volatile_lru`) or reports that it cannot
  (`noeviction`, or nothing evictable under `volatile_lru`).

  Victims come from a **clock sweep**, not a recency list: each live entry
  carries a saturating reference counter plus a live bit in one byte of the
  entry, and a hand walks `entries` decrementing counters until it reaches one
  at zero. A counter of 5 survives five passes, so a hot key wins a full lap
  against a cold one at no per-access cost beyond a byte store into a cache line
  the lookup already touched. The sweep is bounded by `ref_max + 1` laps; when
  nothing reaches zero, `evict_one` reports failure and the reclaim path below
  runs instead of spinning. Entries past their TTL are taken as soon as the hand
  reaches them, which is what the old separate expired-key scan did.

  The four intrusive LRU pointers this replaced cost 32 bytes per entry plus an
  8-byte access stamp. Measured at 1M keys: 152.8 bytes per key before, 112.8
  after — 26% less memory — with the eviction path roughly twice as fast and no
  loss of hit rate.

  The cap is 5, matching Postgres' `BM_MAX_USAGE_COUNT`. A single-bit clock is
  cheaper to sweep but cannot tell a key read six times from a key read once, so
  a hot set loses to a one-shot scan: measured hot-set survival after a scan of
  one cache-capacity in new keys was 100% at 5 and 3% at 1, for roughly 12% more
  sweep time. Giving the counter a nibble array beside `entries` instead of
  keeping it in the entry was also measured; it costs 0.5 bytes per key more
  (the entry byte is free padding) and evicts slightly slower, so it was dropped.

- When eviction alone cannot get under budget, the store reclaims memory that
  isn't holding live data: it destroys pooled deleted entries and shrinks the
  entry/slot arrays to their live size (both keep a high-water mark otherwise).
  Without this, a server that once held many keys could never satisfy a lower
  `maxmemory`, because the pool alone counted against the budget.
- If the budget still can't be met, commands flagged `denyoom` (the Redis
  `CMD_DENYOOM` set: `SET`, `MSET`, `LPUSH`, `RPUSH`, `LSET`, `APPEND`,
  `INCR*`, `DECR*`, `RENAME`, `TS.*`, `BF.*`, ...) are rejected **before they
  execute** with Redis' error:
  `-OOM command not allowed when used memory > 'maxmemory'.`
- Commands that only free memory (`DEL`, `LPOP`, `RPOP`, `FLUSHDB`, ...) and
  reads keep working, so a full instance can be drained.
- **During command execution the budget is soft**: allocations may overshoot
  it, and eviction is deferred to the next command boundary. This is the same
  trade-off Redis makes (memory may exceed `maxmemory` by one command), and it
  matters for correctness: evicting in the middle of a command would free
  entries that the running handler still points at.
- `resize()` correctly tracks grow/shrink delta
- `free()` subtracts the freed size
- Bound to the store via `attach_store()` for eviction callbacks

Direct `Store` users that bypass command execution (unit tests, benchmarks,
AOF/RDB loading) still get the hard, allocation-time budget check.

`CONFIG SET maxmemory <bytes>` updates the limit at runtime, like Redis.

All store-owned data allocates through `kv_allocator.allocator()`:
- `StoreEntry` structs (keys ≤ 23 bytes are inline; longer keys heap-allocate)
- `ZedisValue.string` for strings > 23 bytes (short strings are inline)
- `ZedisList` nodes and data
- `TimeSeries` chunks and sample storage
- `ScalableBloomFilter` chains and bit arrays
- Store hash-table internals (`slots`/`entries` arrays, reallocation)

## Per-Client Parse Arena

Commands that are already fully buffered in the client's 16 KB socket read buffer are
parsed zero-copy: argument slices point into the read buffer and stay valid until the
next read, which only happens after the command executed.

Other commands (arguments that don't fit in the read buffer, or are still arriving)
are parsed into a per-client `ArenaAllocator` backed by the base allocator. After each
command, `arena.reset(.{ .retain_with_limit = 64 KB })` frees parser allocations while
keeping up to 64 KB for reuse, so one huge argument does not pin memory per
connection. Bulk strings are capped at 512 MB (Redis' `proto-max-bulk-len`). Parser
allocations are not charged to the KV budget.

## Command Execution Flow

Client I/O and command execution run in the same domain: client connections run as
zio coroutines (parsing, command execution, response writes). The zio runtime is
always configured with **exactly one executor** (`RuntimeOptions.executors = .exact(1)`),
so commands execute one at a time on one OS thread, and there is **no store lock**
and no cross-thread command hand-off:

1. Client coroutine parses the command in its per-client arena
2. Client coroutine runs the memory gate (evict to budget, or reject `denyoom`
   commands with `-OOM`) and executes the command inline:
   - queues the command for the AOF (an in-memory append under a spinlock; the
     AOF writer thread does the file I/O and fsync, see below)
   - executes it via `process_command_direct()` → `registry.execute_command()`,
     building the response in a `StackWriter`
3. The client coroutine writes the response to the socket, resets its arena, and
   flushes the mailbox (pub/sub messages that arrived during execution)

This is only safe because command handlers **never suspend**: no yielding to the
runtime between the start of a command and its last mutation. Two places need care:

- `SAVE` uses blocking file I/O (`std.Io.Threaded.global_single_threaded`), so the
  snapshot cannot interleave with another command. It stalls the executor for its
  duration, like Redis' `SAVE`.
- AOF queueing uses a spinlock, not `zio.Mutex`, so contention with the writer
  thread cannot park the coroutine mid-command.

Socket reads/writes and `appendfsync always` durability waits can suspend, but they
happen outside command execution.

This makes the single executor the serialization boundary: one logical writer for the
store without any per-store lock.

## AOF Writer Thread

AOF file I/O runs on a dedicated OS thread (`aof.Writer`), never on the event loop:

1. Command execution encodes the command into a shared queue under a short spinlock,
   during command execution, so AOF order matches execution order. The spinlock is
   never held across I/O and never suspends the coroutine.
2. The writer thread takes the whole queue, writes it, and fsyncs per `appendfsync`:
   after every batch (`always`), at most once a second (`everysec`), or never (`no`).
3. Under `always`, a client waits for its last logged command to be fsynced before its
   reply is written, outside command execution. One fsync covers every command
   queued while the previous one ran (group commit).

On shutdown the writer drains the queue and fsyncs (unless `no`) before closing.

## StackWriter

Response serialization uses `StackWriter` (src/util/stack_writer.zig):

- 16 KB inline buffer — zero heap allocation for typical responses
- When response exceeds 16 KB, transparently switches to `ArrayListUnmanaged(u8)`
  (allocated from `base_allocator`)
- Custom `Writer.drain` vtable hook handles the transition
- `slice()` returns a contiguous view; `to_owned_slice()` transfers ownership

## ClientMailbox

Per-client message queue used exclusively for pub/sub delivery (not command responses).

- Spinlock-protected linked list of `MessageNode { bytes: []u8, next: ?*MessageNode }`
  (`std.atomic.Mutex`; not lock-free)
- Capacity 256 per mailbox
- Node pool of 4 recycled nodes to reduce allocations
- `acquire_node()` checks the pool before allocating; `release_node()` returns to it
- `take_all()` drains the entire list while holding the mailbox lock
- Messages are written directly to the client socket during `flush_mailbox()`

Each client slot also holds a `zio.Event` set by `enqueue_to_handle()`. The first
`SUBSCRIBE` starts a delivery coroutine that waits on that event and drains the
mailbox, so messages reach clients that are idle (blocked reading the socket).
The delivery task and the client coroutine share the socket under a per-client
write mutex; the store isn't involved.

## Fixed Allocations

Structures allocated once at startup and reused for server lifetime:

- `client_slots: []ClientSlot` — fixed pool of `max_clients` slots (default 10000)
- Lock-free ABA-protected free list for slot allocation/reuse
- Each slot embeds: `ClientMailbox`, `Client` struct,
  atomic state/generation/disconnect fields
- Free list uses tagged pointers (`tag << 32 | index`) to prevent ABA

## Dynamic Allocations

Structures that grow and shrink during operation:

- Pub/sub subscriber lists (dynamic arrays reallocated on subscribe/unsubscribe)
- Mailbox `MessageNode` allocations (per pub/sub message)
- Store contents within KV allocator budget
- `StackWriter` overflow buffers (for large responses)
- AOF write queue (unbounded; drained continuously by the AOF writer thread)

## Memory Budgets and Reporting

`Config.total_memory_budget()` = `fixed_memory_size()` + `kv_memory_budget` + `disk_memory_budget`

With `disk-storage no` the disk share is zero and the old formula holds.
With `disk-storage yes`, `maxmemory` is treated as the KV + disk total:

- an explicit `disk-memory-budget` is subtracted from `maxmemory`;
- otherwise the disk share is a quarter of `maxmemory` (64 MB floor, 1 GB
  ceiling), and the KV budget is reduced by the same amount.

`Config.fixed_memory_size()` = `client_pool_size()` + `pubsub_matrix_size()`
(computed model, not a live measurement)

`Server.get_memory_stats()` returns:
- `fixed_memory_used` — from `Config.fixed_memory_size()` (model-based)
- `kv_memory_used` — from `KeyValueAllocator.get_memory_usage()` (precise)
- `total_allocated` — sum of fixed + kv
- `disk_memory_used` — TidesDB memtable + transactions + the configured block
  cache (an upper bound; v10 does not report cache usage)
- `disk_memory_budget` — the reserved disk share
- `total_budget` — from `Config.total_memory_budget()`

## Disk Tier

`disk-storage yes` adds a cold-value tier (`src/storage/disk.zig` and the
TidesDB binding in `src/storage/disk/tidesdb.zig`). The KV allocator does not
own TidesDB memory: the C engine has no allocator hook, allocates on its own
flush/compaction threads, and would re-enter eviction from those threads. The
two domains share a budget and a reported number, not an allocator.

- At each command boundary, `KeyValueAllocator.enforce_budget()` spills cold
  string values down to `disk-low-watermark` before it evicts anything.
- `noeviction` keeps no clock state, so it cannot spill in this milestone; the
  disk tier requires `allkeys-lru` or `volatile-lru`.
- A spilled entry keeps its key, TTL, reference counter and type in memory; only
  the value payload moves. `KEYS`, `SCAN`, `TTL`, `TYPE` and the clock sweep
  therefore never read from disk.
- The first read materializes the value. Phase 3 does this synchronously on the
  executor, so a cold read stalls the event loop for one disk read.
- `spill_entry()` allocates its encoding scratch from `std.heap.c_allocator`,
  not the KV allocator, because spilling runs outside a command where a KV
  allocation could re-enter eviction.
- `INFO memory` reports `used_memory` (in-memory only), `used_memory_disk`, and
  `used_memory_total`; `METRICS` exposes the same split plus spill/reload
  counters.

Materializing a spilled value during `SAVE`, `BGREWRITEAOF`, or a full-store
iteration loads every value into memory. In disk mode these operations can
exceed the KV budget; the AOF is the supported durability path for this
milestone.

## Reporting Caveats

- `kv_memory_used` is precise (atomic counter in custom allocator)
- `fixed_memory_used` is a configuration model, not a live measurement
- `pubsub_matrix_size()` models channels × subscribers as a dense matrix, but
  actual storage is dynamic/sparse
- `client_pool_size()` models the pool as `max_clients * @sizeOf(Client)`, while the
  server allocates `ClientSlot` (which embeds the mailbox, event and atomics), so
  `fixed_memory_used` is a lower bound even for the modelled structures
- Transient allocations from `base_allocator` (pub/sub arrays, mailbox nodes,
  StackWriter overflow, startup loader allocations) are not tracked in memory stats
- Memory stats are operationally useful but not a complete byte accounting

## Clock

`Clock` (`src/app/clock.zig`) trades accuracy for throughput:

- `clock_update_ms = 0` → always calls `Timestamp.now(.real)` (syscall each access)
- `clock_update_ms > 0` (default 100 ms) → cached timestamp updated periodically
  via coroutine or detached OS thread
- Used by the store for TTL expiry checks and clock reference counting

---

:::note[Source of truth]
This page mirrors `docs/memory-architecture.md` in the repository root. That file stays canonical — update both when the underlying behaviour changes.
:::
