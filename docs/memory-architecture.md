# Memory Architecture

Zedis uses multiple allocation domains to separate concerns: budgeted store data,
long-lived server structures, and per-command parsing.

## Allocation Domains

Three distinct allocation domains:

| Domain                 | Backing                                       | Lifetime        | Budgeted |
| ---------------------- | --------------------------------------------- | --------------- | -------- |
| `base_allocator`       | `GeneralPurposeAllocator` (OS-provided)       | Server lifetime | No       |
| `kv_allocator`         | `KeyValueAllocator` wrapping `base_allocator` | Server lifetime | Yes      |
| Per-client parse arena | `FixedBufferAllocator` on 64KB inline buffer  | Per-command     | No       |

## Base Allocator

Passed from `main` into `Server.initWithConfig()`. Used for general-purpose server
allocations not charged against the KV memory budget:

- Server metadata and config-owned strings
- `client_slots` array (fixed pool, allocated once)
- Command registry lifetime storage (`StringHashMap` keys/values)
- Pub/sub channel names and subscriber arrays (dynamic, grow/shrink with subscriptions)
- AOF/RDB loader allocations during startup
- AOF writer buffer and file handles
- Per-command response `StackWriter` overflow allocations (when response exceeds 16KB)
- Mailbox `MessageNode` allocations (pub/sub delivery)
- Miscellaneous transient allocations

## KV Allocator

`KeyValueAllocator` wraps `base_allocator` with a custom vtable to enforce
`kv_memory_budget` (default 2 GB). Every allocation, resize, and free adjusts
an atomic `memory_used` counter.

- When an allocation would exceed budget:
  - `noeviction` → fails with `error.OutOfMemory`
  - `allkeys_lru` / `volatile_lru` → calls `Store.evictOne()` to free space first
- `resize()` correctly tracks grow/shrink delta
- `free()` subtracts the freed size
- Bound to the store via `attachStore()` for eviction callbacks

All store-owned data allocates through `kv_allocator.allocator()`:
- `StoreEntry` structs (keys ≤ 23 bytes are inline; longer keys heap-allocate)
- `ZedisValue.string` for strings > 23 bytes (short strings are inline)
- `ZedisList` nodes and data
- `TimeSeries` chunks and sample storage
- `ScalableBloomFilter` chains and bit arrays
- Store hash-table internals (`slots`/`entries` arrays, reallocation)

## Per-Client Parse Arena

Each `Client` struct embeds `parse_buffer: [65536]u8` (64 KB). Before each command
parse cycle:

```
fba = FixedBufferAllocator.init(parse_buffer)
arena = ArenaAllocator.init(fba.allocator())
parser = Parser.init(arena.allocator())
```

RESP protocol parsing (argument buffers, bulk data reads) allocates into this arena.
After each command, `arena.reset(.retain_capacity)` frees all parser allocations.

Using a fixed inline buffer avoids `page_allocator` syscalls and does not charge
parser allocations to the KV budget.

## Command Execution Flow

Client I/O and command execution run in the same domain: client connections run as
zio coroutines on the runtime's executor threads (parsing, command execution, response
writes), and the shared store is protected by a single cooperative store lock rather
than being owned by a dedicated thread. There is no cross-thread command hand-off:

1. Client coroutine parses the command in its per-client arena
2. Client coroutine acquires the store lock (`server.store_lock`, a parking
   `zio.Mutex`) and executes the command inline on its own executor thread:
   - writes the command to the AOF (file I/O parks only this coroutine)
   - executes it via `process_command_direct()` → `registry.execute_command()`,
     building the response in a `StackWriter`
3. The store lock is released and the client coroutine writes the response to the
   socket, resets its arena, and flushes the mailbox (pub/sub messages that arrived
   during execution)

Commands are serialized by the store lock (one logical writer) rather than by a
per-command lock in the store data structure.

Why a parking lock and not a raw spinlock: handlers may suspend (AOF file I/O, `SAVE`).
A spinlock held across a suspension deadlocks the runtime once every executor thread is
spinning on it; `zio.Mutex` queues waiters in the runtime instead, and its uncontended
fast path is a single atomic CAS.

## StackWriter

Response serialization uses `StackWriter` (src/stack_writer.zig):

- 16 KB inline buffer — zero heap allocation for typical responses
- When response exceeds 16 KB, transparently switches to `ArrayListUnmanaged(u8)`
  (allocated from `base_allocator`)
- Custom `Writer.drain` vtable hook handles the transition
- `slice()` returns a contiguous view; `toOwnedSlice()` transfers ownership

## ClientMailbox

Per-client message queue used exclusively for pub/sub delivery (not command responses).

- Lock-free linked list of `MessageNode { bytes: []u8, next: ?*MessageNode }`
- Capacity 256 per mailbox
- Node pool of 4 recycled nodes to reduce allocations
- `acquireNode()` checks pool before allocating; `releaseNode()` returns to pool
- `takeAll()` atomically drains the entire list
- Messages are written directly to the client socket during `flushMailbox()`

## Fixed Allocations

Structures allocated once at startup and reused for server lifetime:

- `client_slots: []ClientSlot` — fixed pool of `max_clients` slots (default 10000)
- Lock-free ABA-protected free list for slot allocation/reuse
- Each slot embeds: `ClientMailbox`, `Client` struct (with 64KB parse buffer),
  atomic state/generation/disconnect fields
- Free list uses tagged pointers (`tag << 32 | index`) to prevent ABA

## Dynamic Allocations

Structures that grow and shrink during operation:

- Pub/sub subscriber lists (dynamic arrays reallocated on subscribe/unsubscribe)
- Mailbox `MessageNode` allocations (per pub/sub message)
- Store contents within KV allocator budget
- `StackWriter` overflow buffers (for large responses)
- AOF write buffer (configurable, default 64 KB)

## Memory Budgets and Reporting

`Config.totalMemoryBudget()` = `fixedMemorySize()` + `kv_memory_budget`

`Config.fixedMemorySize()` = `clientPoolSize()` + `pubsubMatrixSize()`
(computed model, not a live measurement)

`Server.getMemoryStats()` returns:
- `fixed_memory_used` — from `Config.fixedMemorySize()` (model-based)
- `kv_memory_used` — from `KeyValueAllocator.getMemoryUsage()` (precise)
- `total_allocated` — sum of fixed + kv
- `total_budget` — from `Config.totalMemoryBudget()`

## Reporting Caveats

- `kv_memory_used` is precise (atomic counter in custom allocator)
- `fixed_memory_used` is a configuration model, not a live measurement
- `pubsubMatrixSize()` models channels × subscribers as a dense matrix, but
  actual storage is dynamic/sparse
- Transient allocations from `base_allocator` (pub/sub arrays, mailbox nodes,
  StackWriter overflow, startup loader allocations) are not tracked in memory stats
- Memory stats are operationally useful but not a complete byte accounting

## Clock

`Clock` (`src/clock.zig`) trades accuracy for throughput:

- `clock_update_ms = 0` → always calls `Timestamp.now(.real)` (syscall each access)
- `clock_update_ms > 0` (default 100 ms) → cached timestamp updated periodically
  via coroutine or detached OS thread
- Used by the store for TTL expiry checks and LRU access tracking
