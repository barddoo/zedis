# Server Architecture

Zedis uses a hybrid concurrency model built on Zig `std.Io.Threaded`.

## Threads And Tasks

- The main thread initializes the threaded I/O runtime, loads config, builds the server, and runs the TCP accept loop.
- Each accepted connection is handled as an `Io.Group.async(...)` task. These tasks own socket reads, RESP parsing, mailbox flushing, and socket writes.
- A single dedicated store thread executes commands against the shared `Store`. This keeps store access serialized instead of relying on store-wide locks.
- The clock may also run as a background I/O task, or fall back to a detached OS thread when concurrency is unavailable.

This means the architecture is not "one OS thread per client" in project code. The explicit application-owned threads are:

- the main thread
- one dedicated store thread
- an optional clock updater fallback thread

Connection work is scheduled through Zig's threaded I/O runtime rather than by manually spawning `std.Thread` for every client.

## Thread Ownership

### Main Thread

- Initializes `std.Io.Threaded`
- Reads configuration
- Builds the server
- Runs the TCP accept loop in `Server.listen()`

### Store Thread

- Runs `storeThreadLoop`
- Drains the shared `CommandQueue`
- Executes commands against the shared `Store`
- Serializes responses
- Enqueues response bytes into the target client's mailbox

### Client Connection Tasks

- Run per accepted connection via `Io.Group.async(...)`
- Read from the socket
- Parse RESP commands
- Copy parsed command arguments into heap-owned buffers
- Enqueue work for the store thread
- Flush mailbox responses back to the socket

## Request Flow

1. The listener accepts a TCP connection.
2. Zedis allocates a client slot from a fixed pool.
3. The client task reads from the socket and parses RESP.
4. The parsed command is enqueued to the shared command queue.
5. The store thread executes the command against the shared store.
6. The store thread writes the encoded response into the client's mailbox.
7. The client task flushes mailbox messages to the socket.

## Coordination Primitives

- `CommandQueue`: many client tasks push, one store thread drains.
- `ClientMailbox`: store thread pushes responses, owning client task drains and writes them.
- Client slots are preallocated and tracked with generation counters to avoid stale handle reuse during disconnect and reconnect cycles.

## Why The Store Is Single-Threaded

Zedis keeps command execution serialized around the shared `Store`.

- Client tasks handle network I/O and parsing concurrently.
- The store thread is the synchronization boundary for command execution.
- This avoids store-wide locking and keeps Redis-like command ordering simpler to reason about.

The tradeoff is that command execution is globally serialized even though connection handling is concurrent.
