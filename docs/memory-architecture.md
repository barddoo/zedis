# Memory Architecture

Zedis uses multiple allocation domains to separate concerns: budgeted store data,
long-lived server structures, and per-command parsing.

## Allocation Domains

Three distinct allocation domains:

| Domain                 | Backing                                       | Lifetime        | Budgeted |
| ---------------------- | --------------------------------------------- | --------------- | -------- |
| `base_allocator`       | `GeneralPurposeAllocator` (OS-provided)       | Server lifetime | No       |
| `kv_allocator`         | `KeyValueAllocator` wrapping `base_allocator` | Server lifetime | Yes      |
| Per-client parse arena | `ArenaAllocator` on the base allocator (keeps ≤64KB) | Per-command | No       |

## Base Allocator

Passed from `main` into `Server.initWithConfig()`. Used for general-purpose server
allocations not charged against the KV memory budget:

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
`kv_memory_budget` (default 2 GB; `0` means unlimited, like `maxmemory 0`).
Every allocation, resize, and free adjusts an atomic `memory_used` counter.

The budget is applied the way Redis applies `maxmemory`:

- **Before every command**, `Server.memory_gate()` calls
  `KeyValueAllocator.enforce_budget()`, which evicts entries until usage is
  within budget (`allkeys_lru` / `volatile_lru`) or reports that it cannot
  (`noeviction`, or nothing evictable under `volatile_lru`).
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
- Bound to the store via `attachStore()` for eviction callbacks

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
- `slice()` returns a contiguous view; `toOwnedSlice()` transfers ownership

## ClientMailbox

Per-client message queue used exclusively for pub/sub delivery (not command responses).

- Lock-free linked list of `MessageNode { bytes: []u8, next: ?*MessageNode }`
- Capacity 256 per mailbox
- Node pool of 4 recycled nodes to reduce allocations
- `acquireNode()` checks pool before allocating; `releaseNode()` returns to pool
- `takeAll()` atomically drains the entire list
- Messages are written directly to the client socket during `flushMailbox()`

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

`Clock` (`src/app/clock.zig`) trades accuracy for throughput:

- `clock_update_ms = 0` → always calls `Timestamp.now(.real)` (syscall each access)
- `clock_update_ms > 0` (default 100 ms) → cached timestamp updated periodically
  via coroutine or detached OS thread
- Used by the store for TTL expiry checks and LRU access tracking
