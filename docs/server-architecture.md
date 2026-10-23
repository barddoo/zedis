# Server Architecture

Zedis runs on zio with **exactly one executor** (`RuntimeOptions.executors = .exact(1)`).
All client coroutines, parsing, command execution and response building run on that
one OS thread.

## Threads And Tasks

- The main thread initializes the zio runtime, loads config, builds the server, and
  runs the TCP accept loop (`Server.listen()`).
- Each accepted connection runs as an `Io.Group.async(...)` coroutine on the single
  executor. Coroutines own socket reads, RESP parsing, command execution, mailbox
  flushing, and socket writes.
- Commands run **inline on the client coroutine**. There is no store thread, no
  command queue, and no store lock.
- The AOF writer is a dedicated OS thread (`aof.Writer`) that owns file writes and
  fsyncs. Commands only append to an in-memory queue.
- The clock updater runs as a background coroutine, or as a detached OS thread when
  the I/O backend has no concurrency (`Clock.start`).

Application-owned threads are therefore: the main/executor thread, the AOF writer
thread, and the optional clock fallback thread. There is no thread per client.

## Request Flow

1. The listener accepts a TCP connection.
2. Zedis allocates a client slot from a fixed pool.
3. The client coroutine reads from the socket and parses a RESP command (zero-copy
   from the read buffer when the whole command is buffered).
4. The memory gate evicts to the KV budget, or rejects `denyoom` commands with `-OOM`.
5. The command executes inline against the shared `Store`; writes are queued for the
   AOF.
6. The response is serialized into a `StackWriter` and written to the socket.
7. Pub/sub messages queued in the client's mailbox are flushed after the command;
   the per-client delivery coroutine also drains them while the client is idle.

## Serialization

With one executor, only one coroutine runs at a time, so command execution is
serialized without a store lock. This relies on commands never suspending:

- `SAVE` uses blocking file I/O, so a snapshot cannot interleave with another
  command (it stalls the server for its duration, like Redis' `SAVE`).
- AOF queueing uses a spinlock, so contention with the writer thread cannot park the
  coroutine in the middle of a command.

Socket I/O and `appendfsync always` durability waits can suspend, but only outside
command execution. If a handler ever needs to suspend, it must not mutate the store
around that suspension (or the single-executor/no-lock invariant no longer holds).

## Coordination Primitives

- `ClientMailbox`: spinlock-protected queue for pub/sub delivery (not lock-free),
  drained by the client coroutine and by the per-client delivery coroutine while the
  client is idle.
- Client slots are preallocated and tracked with generation counters to avoid stale
  handle reuse during disconnect and reconnect cycles.
- AOF queue: spinlock shared with the writer thread; the critical section is the
  in-memory queue swap/append only.

## Why One Executor

Store access is globally serialized either way. With multiple executors, coroutines
and the store bounce between threads on every command, adding contention and cache
pressure for no throughput benefit. On the benchmark workload one executor ran at
~2.66M rps on ~0.75 cores, while `.auto` ran at ~1.2M rps using ~4.5 cores (one
executor was also ~35% faster without pipelining).
