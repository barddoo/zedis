const std = @import("std");
const Store = @import("../store.zig").Store;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;
const Value = @import("../parser.zig").Value;
const config_mod = @import("../config.zig");
const KeyValueAllocator = @import("../kv_allocator.zig").KeyValueAllocator;
const resp = @import("../commands/resp.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Response from shard containing RESP-formatted data
pub const Response = struct {
    data: []const u8,       // RESP-formatted response
    arena: *std.heap.ArenaAllocator,  // Arena that owns the response data
    allocator: std.mem.Allocator,     // Allocator for the arena pointer
};

/// Task sent to shard for execution (async, non-blocking)
/// Each task owns an arena allocator for command arguments
pub const ShardTask = struct {
    command_args: []Value,                     // Command arguments (owned by task arena)
    response_queue: *std.Io.Queue(*Response),  // Lock-free queue for response pointers
    client_db_index: u8,                       // Which database (0-15) to use
    arena: *std.heap.ArenaAllocator,           // Arena for this task
    allocator: std.mem.Allocator,              // Allocator that created the arena pointer

    pub fn deinit(self: *ShardTask) void {
        const arena_ptr = self.arena;
        arena_ptr.deinit();
        self.allocator.destroy(arena_ptr); // Free the arena pointer itself
    }
};

/// Shard owning exclusive databases following DragonflyDB's shared-nothing design
/// Each shard runs in its own thread with no lock contention during execution
pub const Shard = struct {
    shard_id: usize,
    databases: [16]Store, // Exclusively owned by this shard (shared-nothing!)
    message_queue: std.Io.Queue(ShardTask),
    message_queue_buffer: []ShardTask,
    registry: CommandRegistry, // Each shard owns its registry copy (thread-safe!)
    kv_allocator: *KeyValueAllocator, // Heap-allocated to prevent move issues
    io: Io,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(
        shard_id: usize,
        base_allocator: Allocator,
        registry: CommandRegistry, // Take ownership of registry copy
        config: config_mod.Config,
        io: Io,
        num_shards: u8,
    ) !Shard {
        // Divide memory budget among shards
        const per_shard_budget = config.kv_memory_budget / num_shards;

        // Allocate KV allocator on heap to prevent move issues
        const kv_allocator = try base_allocator.create(KeyValueAllocator);
        errdefer base_allocator.destroy(kv_allocator);

        kv_allocator.* = try KeyValueAllocator.init(
            base_allocator,
            per_shard_budget,
            config.eviction_policy,
        );

        // Allocate message queue buffer
        const queue_buffer = try base_allocator.alloc(ShardTask, 1024);

        var shard = Shard{
            .shard_id = shard_id,
            .databases = undefined, // Will initialize below
            .message_queue = std.Io.Queue(ShardTask).init(queue_buffer),
            .message_queue_buffer = queue_buffer,
            .registry = registry, // Each shard gets its own registry copy
            .kv_allocator = kv_allocator,
            .io = io,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
        };

        // Initialize databases with stable allocator pointer
        for (&shard.databases) |*db| {
            db.* = Store.init(shard.kv_allocator.allocator(), io, config.initial_capacity);
        }

        return shard;
    }

    pub fn deinit(self: *Shard, base_allocator: Allocator) void {
        // Deinitialize all databases
        for (&self.databases) |*db| {
            db.deinit();
        }

        // Deinitialize registry
        self.registry.deinit();

        // Deallocate message queue buffer
        base_allocator.free(self.message_queue_buffer);

        // Deinitialize and free KV allocator
        self.kv_allocator.deinit();
        base_allocator.destroy(self.kv_allocator);
    }

    /// Start the shard thread
    pub fn start(self: *Shard) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Main shard loop - receives and processes tasks
    fn run(self: *Shard) void {
        var task_buffer: [1]ShardTask = undefined;

        while (self.running.load(.acquire)) {
            // Block until task available (message passing from client threads)
            const count = self.message_queue.get(
                self.io,
                &task_buffer,
                1, // min: block until at least 1 task
            ) catch break; // Canceled = shutdown

            if (count == 0) break; // Queue closed

            const task = task_buffer[0];
            // Note: task arena ownership is transferred to Response (client will free it)

            self.executeTask(task);
        }
    }

    /// Execute task on this shard's databases (shared-nothing execution!)
    fn executeTask(self: *Shard, task: ShardTask) void {
        // Create RESP response buffer using task's arena
        var response_buf: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&response_buf);

        // Get the store for this client's current database
        // No locking needed - we own this database exclusively!
        const store = &self.databases[task.client_db_index];

        // Execute command via registry
        self.registry.executeCommandShard(
            &writer,
            store,
            task.command_args,
        ) catch |err| {
            // On error, format error message
            formatError(&writer, err);
        };

        // Allocate response data in task arena (will be freed by client)
        const buffered = writer.buffered();
        const response_data = task.arena.allocator().dupe(u8, buffered) catch {
            // If OOM, send minimal error
            const oom_error = "-ERR out of memory\r\n";
            const oom_data = task.arena.allocator().dupe(u8, oom_error) catch return;

            // Allocate Response on heap
            const response_ptr = std.heap.page_allocator.create(Response) catch return;
            response_ptr.* = Response{
                .data = oom_data,
                .arena = task.arena,
                .allocator = task.allocator,
            };

            task.response_queue.putOne(self.io, response_ptr) catch {
                std.heap.page_allocator.destroy(response_ptr);
            };
            return;
        };

        // Allocate Response on heap (safer for queue transfer)
        const response_ptr = std.heap.page_allocator.create(Response) catch {
            // Cleanup arena if can't allocate response
            task.arena.deinit();
            task.allocator.destroy(task.arena);
            return;
        };

        response_ptr.* = Response{
            .data = response_data,
            .arena = task.arena,
            .allocator = task.allocator,
        };

        // Non-blocking enqueue (client will receive pointer asynchronously)
        task.response_queue.putOne(self.io, response_ptr) catch {
            // Client disconnected - cleanup everything
            response_ptr.arena.deinit();
            response_ptr.allocator.destroy(response_ptr.arena);
            std.heap.page_allocator.destroy(response_ptr);
        };
    }

    fn formatError(writer: *std.Io.Writer, err: anyerror) void {
        const msg = switch (err) {
            error.WrongType => "WRONGTYPE Operation against a key holding the wrong kind of value",
            error.ValueNotInteger => "value is not an integer or out of range",
            error.InvalidFloat => "value is not a valid float",
            error.Overflow => "increment or decrement would overflow",
            error.KeyNotFound => "no such key",
            error.IndexOutOfRange => "index out of range",
            error.NoSuchKey => "no such key",
            else => "while processing command",
        };

        // Format as RESP error
        resp.writeError(writer, msg) catch {};
    }

    /// Stop the shard thread
    pub fn stop(self: *Shard) void {
        self.running.store(false, .release);
        // Note: Queue cancellation will wake the shard thread
    }

    /// Wait for shard thread to finish
    pub fn join(self: *Shard) void {
        if (self.thread) |thread| {
            thread.join();
        }
    }
};
