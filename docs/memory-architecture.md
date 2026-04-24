# Memory Architecture

Zedis uses multiple allocation domains rather than a single global allocator policy.

## Overview

The current layout is split across four main paths:

- `base_allocator`: general server allocations not tracked by the KV memory budget
- `KeyValueAllocator`: wraps the base allocator and enforces the store memory budget
- `temp_arena`: arena-backed temporary allocations used during startup loading paths
- `std.heap.page_allocator`: per-client parsing arena backing

This is a hybrid model. Some memory is long-lived and tied to server lifetime, some is budgeted as part of the key-value store, and some is short-lived scratch memory.

## Allocation Domains

### Base Allocator

The base allocator is passed into `main`, then into `Server.initWithConfig()`, and is used for general-purpose allocations such as:

- server-owned metadata and configuration-owned strings
- client slot storage
- command registry lifetime allocations
- pub/sub channel names and subscriber arrays
- command queue nodes and per-command copied argument buffers
- response serialization buffers and mailbox message nodes

These allocations are not charged against `kv_memory_budget`.

### KV Allocator

The shared `Store` is initialized with `kv_allocator.allocator()` rather than the raw base allocator.

- `KeyValueAllocator` tracks live bytes with `memory_used`
- it enforces `kv_memory_budget`
- when an allocation would exceed budget, it tries eviction first if the configured policy allows it
- with `noeviction`, allocation failure becomes `error.OutOfMemory`

This is the allocator that backs store-owned data such as keys, values, and store-internal containers.

## Temporary Memory

### Startup Arena

The server creates `temp_arena` with `std.heap.ArenaAllocator.init(base_allocator)` and uses it for startup loading work such as AOF and RDB reads.

Important nuance:

- `temp_arena_size` exists in config and contributes to reported budget totals
- but the arena is not currently created with an enforced hard cap
- in practice this means `temp_arena_size` is a budgeting and reporting target, not a strict allocator limit

### Per-Client Parse Arena

Each client handler creates an `ArenaAllocator` on top of `std.heap.page_allocator`.

- RESP parsing allocates into this arena
- the arena is reset after each command
- this keeps parser allocations short-lived without charging them to the KV budget

## Runtime Allocation Behavior

Zedis does still allocate during command handling today.

Examples from the request path:

- the parser allocates argument buffers in the per-client parse arena
- the client duplicates parsed arguments into heap-owned buffers before enqueueing a command for the store thread
- the store thread uses `std.Io.Writer.Allocating` to build a response buffer
- the response is copied into a mailbox message node before the client flushes it to the socket

So the older claim that command execution performs no runtime allocation is no longer accurate for the current codebase.

## Fixed And Dynamic Memory

Some structures are effectively fixed for server lifetime:

- the `client_slots` array is allocated once at startup
- each slot embeds mailbox state and client storage
- the free-list and generation counters allow slot reuse without reallocating the pool itself

Other structures remain dynamic:

- pub/sub subscriber lists grow and shrink dynamically
- mailbox message nodes are allocated per queued response
- command queue nodes are allocated per command
- store contents grow and shrink within the KV allocator budget

## Memory Budgets And Reporting

`Config.totalMemoryBudget()` currently reports:

- `fixedMemorySize()`
- `kv_memory_budget`
- `temp_arena_size`

`Server.getMemoryStats()` reports:

- `fixed_memory_used`
- `kv_memory_used`
- `temp_arena_used`
- `total_allocated`
- `total_budget`

## Reporting Caveats

There are a few important caveats in the current implementation:

- `kv_memory_used` is the most precise figure because it comes from `KeyValueAllocator`
- `temp_arena_used` is derived from arena capacity state and only covers that arena
- `fixed_memory_used` is currently based on `Config.fixedMemorySize()`, which is a configuration model, not a live measurement of actual allocated bytes
- `pubsubMatrixSize()` contributes to `fixedMemorySize()`, but pub/sub subscriber storage is actually allocated dynamically rather than preallocated as one giant matrix
- transient allocations from the base allocator or `page_allocator` are not part of `kv_memory_used`

Because of that, the memory stats are useful operationally, but they are not a full exact accounting of every byte the process may hold at runtime.

## Design Intent

The current design tries to separate concerns:

- store data is budgeted and eviction-aware
- long-lived server structures are simple and explicit
- startup scratch space is isolated in an arena
- parsing scratch space is isolated per client

That gives Zedis a clearer memory model than a single unconstrained allocator, while still leaving some runtime allocations in the request path.
