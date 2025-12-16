const std = @import("std");
const Store = @import("../store.zig").Store;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;
const Value = @import("../parser.zig").Value;
const config_mod = @import("../config.zig");
const KeyValueAllocator = @import("../kv_allocator.zig").KeyValueAllocator;
const resp = @import("../commands/resp.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Response future for async result delivery between client and shard threads
/// Uses atomic operations and condition variables for thread-safe synchronization
pub const ResponseFuture = struct {
    state: std.atomic.Value(FutureState),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    response: ?[]const u8,
    error_msg: ?[]const u8,
    allocator: Allocator,

    pub const FutureState = enum(u8) {
        pending,
        completed,
        error_state,
    };

    pub fn init(allocator: Allocator) ResponseFuture {
        return .{
            .state = std.atomic.Value(FutureState).init(.pending),
            .mutex = .{},
            .condition = .{},
            .response = null,
            .error_msg = null,
            .allocator = allocator,
        };
    }

    /// Wait for shard to complete the task (blocks until result available)
    pub fn wait(self: *ResponseFuture) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.state.load(.acquire) == .pending) {
            self.condition.wait(&self.mutex);
        }

        return switch (self.state.load(.acquire)) {
            .completed => self.response.?,
            .error_state => error.CommandFailed,
            .pending => unreachable,
        };
    }

    /// Complete the future with success result
    pub fn complete(self: *ResponseFuture, response: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.response = response;
        self.state.store(.completed, .release);
        self.condition.signal();
    }

    /// Complete the future with error
    pub fn completeError(self: *ResponseFuture, error_msg: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.error_msg = error_msg;
        self.state.store(.error_state, .release);
        self.condition.signal();
    }

    pub fn deinit(self: *ResponseFuture) void {
        if (self.response) |r| self.allocator.free(r);
        if (self.error_msg) |e| self.allocator.free(e);
    }
};

/// Task sent to shard for execution
/// Each task owns an arena allocator for command arguments
pub const ShardTask = struct {
    command_args: []Value,        // Command arguments (owned by task arena)
    response_future: *ResponseFuture,  // Where to send result
    client_db_index: u8,          // Which database (0-15) to use
    arena: *std.heap.ArenaAllocator,  // Arena for this task
    allocator: std.mem.Allocator,     // Allocator that created the arena pointer

    pub fn deinit(self: *ShardTask) void {
        const arena_ptr = self.arena;
        arena_ptr.deinit();
        self.allocator.destroy(arena_ptr);  // Free the arena pointer itself
    }
};

/// Shard owning exclusive databases following DragonflyDB's shared-nothing design
/// Each shard runs in its own thread with no lock contention during execution
pub const Shard = struct {
    shard_id: usize,
    databases: [16]Store,         // Exclusively owned by this shard (shared-nothing!)
    message_queue: std.Io.Queue(ShardTask),
    message_queue_buffer: []ShardTask,
    registry: CommandRegistry,    // Each shard owns its registry copy (thread-safe!)
    kv_allocator: *KeyValueAllocator,  // Heap-allocated to prevent move issues
    io: Io,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(
        shard_id: usize,
        base_allocator: Allocator,
        registry: CommandRegistry,  // Take ownership of registry copy
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
            .registry = registry,  // Each shard gets its own registry copy
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
                1,  // min: block until at least 1 task
            ) catch break;  // Canceled = shutdown

            if (count == 0) break;  // Queue closed

            var task = task_buffer[0];
            defer task.deinit();  // Clean up task arena

            self.executeTask(task);
        }
    }

    /// Execute task on this shard's databases (shared-nothing execution!)
    fn executeTask(self: *Shard, task: ShardTask) void {
        // Create RESP response buffer
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
            // On error, format error message and complete future
            const error_msg = formatError(task.response_future.allocator, err) catch "-ERR unknown error\r\n";
            task.response_future.completeError(error_msg);
            return;
        };

        // Complete future with result
        const buffered = writer.buffered();
        const result = task.response_future.allocator.dupe(u8, buffered) catch {
            task.response_future.completeError("-ERR out of memory\r\n");
            return;
        };
        task.response_future.complete(result) catch {
            task.response_future.completeError("-ERR failed to complete future\r\n");
        };
    }

    fn formatError(allocator: Allocator, err: anyerror) ![]const u8 {
        const msg = switch (err) {
            error.WrongType => "WRONGTYPE Operation against a key holding the wrong kind of value",
            error.ValueNotInteger => "ERR value is not an integer or out of range",
            error.InvalidFloat => "ERR value is not a valid float",
            error.Overflow => "ERR increment or decrement would overflow",
            error.KeyNotFound => "ERR no such key",
            error.IndexOutOfRange => "ERR index out of range",
            error.NoSuchKey => "ERR no such key",
            else => "ERR while processing command",
        };

        // Format as RESP error
        var buf: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try resp.writeError(&writer, msg);
        const buffered = writer.buffered();
        return try allocator.dupe(u8, buffered);
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
