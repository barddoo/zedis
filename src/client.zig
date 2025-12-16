const std = @import("std");
const Stream = std.Io.net.Stream;
const posix = std.posix;
const pollfd = posix.pollfd;
const Parser = @import("parser.zig").Parser;
const Value = @import("parser.zig").Value;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const ZedisObject = store_mod.ZedisObject;
const ZedisValue = store_mod.ZedisValue;
const ZedisList = store_mod.ZedisList;
const PrimitiveValue = store_mod.PrimitiveValue;
const Command = @import("parser.zig").Command;
const CommandRegistry = @import("./commands/registry.zig").CommandRegistry;
const CommandRoutingType = @import("./commands/registry.zig").CommandRoutingType;
const Server = @import("./server.zig");
const PubSubContext = @import("./commands/pubsub.zig").PubSubContext;
const Config = @import("./config.zig").Config;
const resp = @import("./commands/resp.zig");
const Shard = @import("./worker/shard.zig").Shard;
const ResponseFuture = @import("./worker/shard.zig").ResponseFuture;
const ShardTask = @import("./worker/shard.zig").ShardTask;
const aggregator = @import("./coordinator/aggregator.zig");
const error_handler = @import("./error_handler.zig");
const ClientError = error_handler.ClientError;
const handleCommandError = error_handler.handleCommandError;

var next_client_id: std.atomic.Value(u64) = .init(1);

// Buffer size constants for consistent memory allocation
const SMALL_BUFFER_SIZE = 1024;
const LARGE_BUFFER_SIZE = 1024 * 16;

pub const Client = struct {
    allocator: std.mem.Allocator,
    authenticated: bool,
    client_id: u64,
    command_registry: *CommandRegistry,
    connection: Stream,
    current_db: u8,
    is_in_pubsub_mode: bool,
    pubsub_context: *PubSubContext,
    server: *Server,
    io: std.Io,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: Stream,
        pubsub_context: *PubSubContext,
        registry: *CommandRegistry,
        server: *Server,
        io: std.Io,
    ) Client {
        const id = next_client_id.fetchAdd(1, .monotonic);

        return .{
            .allocator = allocator,
            .authenticated = false,
            .client_id = id,
            .command_registry = registry,
            .connection = connection,
            .current_db = 0,
            .is_in_pubsub_mode = false,
            .pubsub_context = pubsub_context,
            .server = server,
            .io = io,
        };
    }

    pub fn deinit(self: *Client) void {
        self.connection.close(self.io);
    }

    pub fn enterPubSubMode(self: *Client) void {
        self.is_in_pubsub_mode = true;
        std.log.debug("Client {} entered pubsub mode", .{self.client_id});
    }

    pub fn handle(self: *Client) !void {
        var reader_buffer: [LARGE_BUFFER_SIZE]u8 = undefined;
        var sr = self.connection.reader(self.io, &reader_buffer);
        const reader = &sr.interface;

        var writer_buffer: [SMALL_BUFFER_SIZE]u8 = undefined;
        var sw = self.connection.writer(self.io, &writer_buffer);
        const writer = &sw.interface;

        // Create per-command arena for parsing (will be freed after enqueueing)
        // Use page_allocator directly as it's thread-safe (multiple clients parse concurrently)
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        while (true) {
            // Use arena allocator for parsing (temporary)
            const arena_allocator = arena.allocator();

            // Parse the incoming command from the client's stream
            var parser = Parser.init(arena_allocator);

            var command = parser.parse(reader) catch |err| {
                // If there's an error (like a closed connection), we stop handling this client
                if (err == error.EndOfStream) {
                    if (self.is_in_pubsub_mode) {
                        std.log.debug("Client {} in pubsub mode, connection ended", .{self.client_id});
                    }
                    return;
                }
                // Socket error, the connection should be closed
                if (err == error.ReadFailed) {
                    if (self.is_in_pubsub_mode) {
                        std.log.debug("Client {} in pubsub mode, read failed", .{self.client_id});
                    }
                    return;
                }
                std.log.err("Parse error: {s}", .{@errorName(err)});

                // Send error response directly (parse errors happen before enqueueing)
                handleCommandError(writer, "", ClientError.ProtocolError);
                writer.flush() catch {};

                // Reset arena to free any partially allocated memory from failed parse
                _ = arena.reset(.retain_capacity);
                continue;
            };
            defer command.deinit();

            const args = command.getArgs();
            if (args.len == 0) {
                handleCommandError(writer, "", ClientError.EmptyCommand);
                writer.flush() catch {};
                _ = arena.reset(.retain_capacity);
                continue;
            }

            // Route command based on routing type
            // Extract command name for error handling
            const command_name = if (args.len > 0) args[0].asSlice() else "";

            self.routeCommand(args) catch |err| {
                // Use centralized error handler
                handleCommandError(writer, command_name, err);
                writer.flush() catch {};
                _ = arena.reset(.retain_capacity);
                continue;
            };

            // Reset arena to free parsing allocations
            _ = arena.reset(.retain_capacity);

            // If we're in pubsub mode after executing a command, stay connected
            if (self.is_in_pubsub_mode) {
                std.log.debug("Client {} staying in pubsub mode", .{self.client_id});
            }
        }
    }

    /// Route command based on its routing type (DragonflyDB-inspired coordinator pattern)
    fn routeCommand(self: *Client, args: []const Value) !void {
        const command_name = args[0].asSlice();

        // Look up command info (registry handles case-insensitive comparison)
        const cmd_info = self.command_registry.get(command_name) orelse {
            return ClientError.UnknownCommand;
        };

        // Route based on routing type
        switch (cmd_info.routing_type) {
            .single_key => {
                // Route to single shard based on hash(key) % num_shards
                try self.routeSingleKeyCommand(args, cmd_info.key_arg_index.?);
            },
            .multi_key => {
                // Broadcast to all shards, aggregate results
                // Use normalized command name from registry for aggregation
                try self.routeMultiKeyCommand(args, cmd_info.name);
            },
            .keyless, .pubsub, .client_only => {
                // Execute on client thread (no routing needed)
                try self.executeLocalCommand(args);
            },
        }
    }

    /// Route single-key command to appropriate shard
    fn routeSingleKeyCommand(self: *Client, args: []const Value, key_arg_index: usize) !void {
        if (key_arg_index >= args.len) {
            return ClientError.InvalidKeyIndex;
        }

        const key = args[key_arg_index].asSlice();
        const shard_id = hashKeyToShard(key, self.server.num_shards);

        // Create task arena to transfer ownership to shard
        var task_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer task_arena.deinit();

        const task_allocator = task_arena.allocator();

        // Copy command args to task arena (ownership transfer)
        const task_args = try task_allocator.alloc(Value, args.len);
        for (args, 0..) |arg, i| {
            const arg_slice = arg.asSlice();
            const copied = try task_allocator.dupe(u8, arg_slice);
            task_args[i] = .{ .data = copied };
        }

        // Create response future
        var response_future = ResponseFuture.init(self.allocator);
        defer response_future.deinit();

        // Create task
        // Use page_allocator for arena pointer (thread-safe, proper alignment)
        const task_arena_ptr = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
        task_arena_ptr.* = task_arena;

        const task = ShardTask{
            .command_args = task_args,
            .response_future = &response_future,
            .client_db_index = self.current_db,
            .arena = task_arena_ptr,
            .allocator = std.heap.page_allocator,
        };

        // Enqueue task to shard
        const shard = &self.server.shards[shard_id];
        _ = shard.message_queue.put(self.io, &.{task}, 1) catch |err| {
            std.heap.page_allocator.destroy(task_arena_ptr);
            std.log.err("Failed to enqueue task to shard {}: {s}", .{ shard_id, @errorName(err) });
            return ClientError.EnqueueFailed;
        };

        // Wait for response from shard
        const response = response_future.wait() catch {
            return ClientError.CommandFailed;
        };

        // Send response to client
        var writer_buffer: [LARGE_BUFFER_SIZE]u8 = undefined;
        var sw = self.connection.writer(self.io, &writer_buffer);
        sw.interface.writeAll(response) catch {};
        sw.interface.flush() catch {};
    }

    /// Route multi-key command to all shards and aggregate results
    fn routeMultiKeyCommand(self: *Client, args: []const Value, command_name: []const u8) !void {
        const num_shards = self.server.num_shards;

        // Create response futures for all shards
        var futures = try self.allocator.alloc(ResponseFuture, num_shards);
        defer self.allocator.free(futures);

        for (futures) |*future| {
            future.* = ResponseFuture.init(self.allocator);
        }
        defer {
            for (futures) |*future| {
                future.deinit();
            }
        }

        // Broadcast command to all shards
        for (0..num_shards) |shard_id| {
            // Create task arena for this shard
            var task_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            errdefer task_arena.deinit();

            const task_allocator = task_arena.allocator();

            // Copy command args to task arena
            const task_args = try task_allocator.alloc(Value, args.len);
            for (args, 0..) |arg, i| {
                const arg_slice = arg.asSlice();
                const copied = try task_allocator.dupe(u8, arg_slice);
                task_args[i] = .{ .data = copied };
            }

            // Use page_allocator for arena pointer (thread-safe, proper alignment)
            const task_arena_ptr = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
            task_arena_ptr.* = task_arena;

            const task = ShardTask{
                .command_args = task_args,
                .response_future = &futures[shard_id],
                .client_db_index = self.current_db,
                .arena = task_arena_ptr,
                .allocator = std.heap.page_allocator,
            };

            // Enqueue to shard
            const shard = &self.server.shards[shard_id];
            _ = shard.message_queue.put(self.io, &.{task}, 1) catch |err| {
                std.heap.page_allocator.destroy(task_arena_ptr);
                std.log.err("Failed to enqueue task to shard {}: {s}", .{ shard_id, @errorName(err) });
                return ClientError.EnqueueFailed;
            };
        }

        // Wait for all responses
        var responses = try self.allocator.alloc([]const u8, num_shards);
        defer self.allocator.free(responses);

        for (futures, 0..) |*future, i| {
            responses[i] = future.wait() catch {
                return ClientError.ShardCommandFailed;
            };
        }

        // Aggregate responses based on command type
        const aggregated = try self.aggregateResponses(command_name, responses);
        defer self.allocator.free(aggregated);

        // Send aggregated response to client
        var writer_buffer: [LARGE_BUFFER_SIZE]u8 = undefined;
        var sw = self.connection.writer(self.io, &writer_buffer);
        sw.interface.writeAll(aggregated) catch {};
        sw.interface.flush() catch {};
    }

    /// Aggregate responses from multiple shards
    fn aggregateResponses(self: *Client, command_name: []const u8, responses: [][]const u8) ![]const u8 {
        if (std.mem.eql(u8, command_name, "MGET")) {
            return aggregator.aggregateMGET(responses, self.allocator);
        } else if (std.mem.eql(u8, command_name, "MSET")) {
            return aggregator.aggregateMSET(responses, self.allocator);
        } else if (std.mem.eql(u8, command_name, "DEL")) {
            return aggregator.aggregateDEL(responses, self.allocator);
        } else if (std.mem.eql(u8, command_name, "KEYS")) {
            return aggregator.aggregateKEYS(responses, self.allocator);
        } else if (std.mem.eql(u8, command_name, "RENAME")) {
            return aggregator.aggregateRENAME(responses, self.allocator);
        } else {
            // Default: return first response
            return try self.allocator.dupe(u8, responses[0]);
        }
    }

    /// Execute command locally on client thread (no shard routing)
    fn executeLocalCommand(self: *Client, args: []const Value) !void {
        var writer_buffer: [LARGE_BUFFER_SIZE]u8 = undefined;
        var sw = self.connection.writer(self.io, &writer_buffer);
        const writer = &sw.interface;

        try self.command_registry.executeCommandClient(self, writer, args);
    }

    pub fn isAuthenticated(self: *Client) bool {
        return self.authenticated or !self.server.config.requiresAuth();
    }

    /// Helper to get the currently selected database from a shard
    /// Note: With sharding, each shard has its own [16]Store array
    pub fn getCurrentStore(self: *Client) *Store {
        // For commands that execute locally (pubsub, client-only, keyless),
        // we need to access a store. Since there's no single "current store" anymore,
        // we return the store from shard 0 (arbitrary choice for local commands)
        return &self.server.shards[0].databases[self.current_db];
    }
};

/// Hash key to determine shard ownership (DragonflyDB-inspired)
fn hashKeyToShard(key: []const u8, num_shards: u32) usize {
    const hash = std.hash.Wyhash.hash(0, key);

    // "Fast Range" mapping (Lemire's method)
    // Avoids the expensive DIV instruction involved in %
    // Casts to u128 to ensure precision before shifting down
    return @intCast((@as(u128, hash) * @as(u128, num_shards)) >> 64);
}
