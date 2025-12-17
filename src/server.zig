const std = @import("std");
const Allocator = std.mem.Allocator;
const time = std.time;
const types = @import("types.zig");
const ConnectionContext = types.ConnectionContext;
const Client = @import("client.zig").Client;
const CommandRegistry = @import("./commands/registry.zig").CommandRegistry;
const command_init = @import("./commands/init.zig");
const Reader = @import("./rdb/zdb.zig").Reader;
const Store = @import("store.zig").Store;
const pubsub = @import("./commands/pubsub.zig");
const PubSubContext = pubsub.PubSubContext;
const config_module = @import("config.zig");
const KeyValueAllocator = @import("kv_allocator.zig");
const aof = @import("./aof/aof.zig");
const Io = std.Io;
const Stream = Io.net.Stream;
const Shard = @import("./worker/shard.zig").Shard;

const Server = @This();

// Configuration
config: config_module.Config,

// Base allocator (only for server initialization)
base_allocator: std.mem.Allocator,

// Network
address: Io.net.IpAddress,
listener: Io.net.Server,
io: Io,

// Fixed allocations (pre-allocated, never freed individually)
client_pool: []Client,
client_registries: []CommandRegistry, // One registry per client slot (thread-safe)
client_pool_bitmap: std.bit_set.DynamicBitSet,
client_pool_mutex: std.Thread.Mutex,

// Map of channel_name -> array of client_id
pubsub_map: std.StringHashMap([]u64),

// Arena for temporary/short-lived allocations
temp_arena: std.heap.ArenaAllocator,

// Shared-nothing shards (DragonflyDB-inspired architecture)
shards: []Shard,
num_shards: u8,

pubsub_context: PubSubContext,

// Metadata
redisVersion: ?[]u8 = undefined,
createdTime: i64,

// AOF logging
aof_writer: aof.Writer,

pub fn initWithConfig(
    base_allocator: Allocator,
    host: []const u8,
    port: u16,
    config: config_module.Config,
    io: Io,
) !Server {
    const address = try Io.net.IpAddress.parse(host, port);

    const listener = try address.listen(io, .{ .kernel_backlog = 128 * 10 });

    // Initialize temp arena for temporary allocations
    const temp_arena = std.heap.ArenaAllocator.init(base_allocator);

    // Initialize command registry with page_allocator (thread-safe, proper alignment for concurrent access)
    var registry = try command_init.initRegistry(std.heap.page_allocator);

    // Determine number of shards (default 4, recommend ≤ CPU cores)
    const num_shards = config.num_workers orelse 4;
    std.log.info("Initializing {} shards (DragonflyDB-inspired shared-nothing architecture)", .{num_shards});

    // Allocate and initialize shards
    const shards = try base_allocator.alloc(Shard, num_shards);
    for (shards, 0..) |*shard, i| {
        // Clone registry for this shard (each shard gets its own copy for thread-safety)
        const shard_registry = try registry.clone(std.heap.page_allocator);
        shard.* = try Shard.init(
            i,
            base_allocator,
            shard_registry,
            config,
            io,
            num_shards,
        );
    }

    // Allocate fixed memory pools on heap
    const client_pool = try base_allocator.alloc(Client, config.max_clients);
    @memset(client_pool, undefined);

    // Allocate one registry per client slot (thread-safe, no shared HashMap access)
    const client_registries = try base_allocator.alloc(CommandRegistry, config.max_clients);
    for (client_registries) |*client_registry| {
        client_registry.* = try registry.clone(std.heap.page_allocator);
    }

    const ts = try Io.Clock.real.now(io);
    const now = ts.toMilliseconds();

    var server = Server{
        .config = config,
        .base_allocator = base_allocator,
        .address = address,
        .listener = listener,
        .pubsub_map = .init(base_allocator),
        .io = io,

        // Fixed allocations - heap allocated
        .client_pool = client_pool,
        .client_registries = client_registries,
        .client_pool_bitmap = try .initFull(base_allocator, config.max_clients),
        .client_pool_mutex = .{},

        // Arena for temporary allocations
        .temp_arena = temp_arena,

        // Shards
        .shards = shards,
        .num_shards = num_shards,
        .pubsub_context = undefined, // Will be initialized after server creation

        // Metadata
        .redisVersion = undefined,
        .createdTime = now,

        // AOF
        .aof_writer = try aof.Writer.init(false),
    };

    if (config.requiresAuth()) {
        std.log.info("Authentication required", .{});
    } else {
        std.log.debug("No authentication required", .{});
    }

    server.pubsub_context = PubSubContext.init(&server);

    // Start shard threads (DragonflyDB-inspired shared-nothing execution)
    for (server.shards) |*shard| {
        try shard.start();
    }
    std.log.info("Started {} shard threads", .{num_shards});

    // TODO: AOF/RDB loading temporarily disabled for multi-shard architecture
    // Will need to distribute keys across shards based on hash(key) % num_shards
    // For now, starting with fresh databases on each shard

    std.log.info("Server initialized - Shards: {}, Fixed: {}MB, Total KV: {}MB, Arena: {}MB", .{
        num_shards,
        config.fixedMemorySize() / (1024 * 1024),
        config.kv_memory_budget / (1024 * 1024),
        config.temp_arena_size / (1024 * 1024),
    });

    return server;
}

pub fn deinit(self: *Server) void {
    // Stop and cleanup shards
    for (self.shards) |*shard| {
        shard.stop();
    }
    for (self.shards) |*shard| {
        shard.join();
    }
    for (self.shards) |*shard| {
        shard.deinit(self.base_allocator);
    }
    self.base_allocator.free(self.shards);

    // Network cleanup
    self.listener.deinit(self.io);

    // Clean up client registries
    for (self.client_registries) |*client_registry| {
        client_registry.deinit();
    }
    self.base_allocator.free(self.client_registries);

    // Clean up pubsub map
    var iterator = self.pubsub_map.iterator();
    while (iterator.next()) |entry| {
        self.base_allocator.free(entry.value_ptr.*);
    }
    self.pubsub_map.deinit();

    // Free heap allocated fixed memory pools
    self.base_allocator.free(self.client_pool);
    self.client_pool_bitmap.deinit();

    // Allocator cleanup
    self.temp_arena.deinit();

    // AOF Deinit
    self.aof_writer.deinit();

    std.log.info("Server deinitialized - all memory freed", .{});
}

// The main server loop. It waits for incoming connections and
// handles each client concurrently using group async.
pub fn listen(self: *Server) !void {
    var group = std.Io.Group.init;
    defer group.wait(self.io); // Ensure all connections finish on shutdown

    while (true) {
        const conn = self.listener.accept(self.io) catch |err| {
            std.log.err("Error accepting connection: {s}", .{@errorName(err)});
            continue;
        };

        // Handle connection concurrently using group async
        group.concurrent(self.io, Server.handleConnectionAsync, .{ self, conn }) catch |err| {
            std.log.err("Failed to spawn connection handler: {s}", .{@errorName(err)});
            conn.close(self.io);
            continue;
        };
    }
}

// Wrapper for handleConnection that doesn't return errors (required by group.concurrent)
fn handleConnectionAsync(self: *Server, conn: Stream) void {
    self.handleConnection(conn) catch |err| {
        std.log.err("Connection error: {s}", .{@errorName(err)});
    };
}

fn handleConnection(self: *Server, conn: Stream) !void {
    // Allocate client from fixed pool
    const client_info = self.allocateClient() orelse {
        std.log.warn("Maximum client connections reached, rejecting connection", .{});
        conn.close(self.io);
        return;
    };

    // Initialize client in the allocated slot with its dedicated registry
    client_info.client.* = try Client.init(
        self.base_allocator,
        conn,
        &self.pubsub_context,
        client_info.registry,
        self,
        self.io,
    );

    defer {
        // Clean up client and return slot to pool
        // For pubsub clients that disconnected, clean them up from all channels first
        if (client_info.client.is_in_pubsub_mode) {
            // Remove this client from all channels
            self.cleanupDisconnectedPubSubClient(client_info.client.client_id);
            std.log.debug("Client {} removed from all channels and deallocated", .{client_info.client.client_id});
        }

        // Always clean up and deallocate when connection ends
        client_info.client.deinit();
        self.deallocateClient(client_info.client);
        std.log.debug("Client {} deallocated from pool", .{client_info.client.client_id});
    }

    try client_info.client.handle();
    std.log.debug("Client {} handled", .{client_info.client.client_id});
}

// Client pool management methods (thread-safe)
const ClientAllocation = struct {
    client: *Client,
    registry: *CommandRegistry,
};

pub fn allocateClient(self: *Server) ?ClientAllocation {
    self.client_pool_mutex.lock();
    defer self.client_pool_mutex.unlock();

    const first_free = self.client_pool_bitmap.findFirstSet() orelse return null;
    self.client_pool_bitmap.unset(first_free);
    return .{
        .client = &self.client_pool[first_free],
        .registry = &self.client_registries[first_free],
    };
}

pub fn deallocateClient(self: *Server, client: *Client) void {
    self.client_pool_mutex.lock();
    defer self.client_pool_mutex.unlock();

    // Find the client index in the pool
    const pool_ptr = @intFromPtr(&self.client_pool[0]);
    const client_ptr = @intFromPtr(client);
    const client_size = @sizeOf(Client);

    if (client_ptr >= pool_ptr and client_ptr < pool_ptr + (self.config.max_clients * client_size)) {
        const index = (client_ptr - pool_ptr) / client_size;
        self.client_pool_bitmap.set(index);
    }
}

// Pub/sub HashMap management methods
pub fn ensureChannelExists(self: *Server, channel_name: []const u8) !void {
    // Check if channel already exists
    if (self.pubsub_map.contains(channel_name)) {
        return;
    }

    // Create new empty subscriber list for this channel
    const subscribers = try self.base_allocator.alloc(u64, 0);
    try self.pubsub_map.put(channel_name, subscribers);
}

pub fn subscribeToChannel(self: *Server, channel_name: []const u8, client_id: u64) !void {
    // Ensure channel exists
    try self.ensureChannelExists(channel_name);

    // Get current subscribers
    const current_subscribers = self.pubsub_map.get(channel_name).?;

    // Check if client is already subscribed
    for (current_subscribers) |existing_id| {
        if (existing_id == client_id) {
            return; // Already subscribed, no-op
        }
    }

    // Check limit
    if (current_subscribers.len >= self.config.max_subscribers_per_channel) {
        return error.ChannelFull;
    }

    // Add client to channel by reallocating the slice
    const new_subscribers = try self.base_allocator.realloc(current_subscribers, current_subscribers.len + 1);
    new_subscribers[new_subscribers.len - 1] = client_id;
    try self.pubsub_map.put(channel_name, new_subscribers);
}

pub fn unsubscribeFromChannel(self: *Server, channel_name: []const u8, client_id: u64) !void {
    // Get current subscribers
    const current_subscribers = self.pubsub_map.get(channel_name) orelse return;

    // Find the client in the subscribers list
    for (current_subscribers, 0..) |existing_id, i| {
        if (existing_id == client_id) {
            // Create new slice without this client
            const new_subscribers = try self.base_allocator.alloc(u64, current_subscribers.len - 1);

            // Copy elements before the removed one
            @memcpy(new_subscribers[0..i], current_subscribers[0..i]);

            // Copy elements after the removed one
            if (i < current_subscribers.len - 1) {
                @memcpy(new_subscribers[i..], current_subscribers[i + 1 ..]);
            }

            // Free old slice and update map
            self.base_allocator.free(current_subscribers);

            if (new_subscribers.len == 0) {
                // Remove channel entirely if no subscribers
                _ = self.pubsub_map.remove(channel_name);
                self.base_allocator.free(new_subscribers);
            } else {
                try self.pubsub_map.put(channel_name, new_subscribers);
            }
            return;
        }
    }
}

// Clean up a disconnected pubsub client from all channels
pub fn cleanupDisconnectedPubSubClient(self: *Server, client_id: u64) void {
    // Iterate through all channels and remove this client
    var channel_iterator = self.pubsub_map.iterator();
    while (channel_iterator.next()) |entry| {
        const channel_name = entry.key_ptr.*;
        self.unsubscribeFromChannel(channel_name, client_id) catch |err| {
            std.log.warn("Failed to unsubscribe client {} from channel {s}: {s}", .{ client_id, channel_name, @errorName(err) });
        };
    }
}

// Memory statistics
pub fn getMemoryStats(self: *Server) config_module.MemoryStats {
    const fixed_size = self.config.fixedMemorySize();
    const total_budget = self.config.totalMemoryBudget();

    // Sum KV memory usage across all shards
    var total_kv_memory: usize = 0;
    for (self.shards) |*shard| {
        total_kv_memory += shard.kv_allocator.getMemoryUsage();
    }

    const temp_arena_used = self.temp_arena.queryCapacity() - self.temp_arena.state.buffer_list.first.?.data.len;

    return config_module.MemoryStats{
        .fixed_memory_used = fixed_size,
        .kv_memory_used = total_kv_memory,
        .temp_arena_used = temp_arena_used,
        .total_allocated = fixed_size + total_kv_memory + temp_arena_used,
        .total_budget = total_budget,
    };
}
pub fn getChannelSubscribers(self: *Server, channel_name: []const u8) []const u64 {
    return self.pubsub_map.get(channel_name) orelse &[_]u64{};
}

pub fn getChannelCount(self: *Server) u32 {
    return @intCast(self.pubsub_map.count());
}

pub fn getChannelNames(self: *Server) std.StringHashMap([]u64).KeyIterator {
    return self.pubsub_map.keyIterator();
}

pub fn findClientById(self: *Server, client_id: u64) ?*Client {
    for (self.client_pool, 0..) |*client, index| {
        // if (!self.client_pool_bitmap.isSet(index) and client.client_id == client_id) {
        //     if (client.client_id == client_id) {
        //         return client;
        //     }
        // }

        _ = index;
        if (client.client_id == client_id) {
            if (client.client_id == client_id) {
                return client;
            }
        }
    }
    return null;
}

// Tests for thread-safe registry architecture
const testing = std.testing;

test "server client registries array allocated per max_clients" {
    const config = config_module.Config{
        .max_clients = 1,
        .max_subscribers_per_channel = 1,
        .num_workers = 1,
        .requirepass = null,
        .kv_memory_budget = 1024,
        .temp_arena_size = 1024,
    };

    var server = try Server.initWithConfig(
        testing.allocator,
        "127.0.0.1",
        6380,
        config,
        std.testing.io,
    );
    defer server.deinit();

    std.debug.print("Registries {any}", .{server.client_registries.len});

    // Verify client_registries array has one entry per max_clients
    try testing.expectEqual(@as(usize, 1), server.client_registries.len);

    // Verify each registry is initialized
    for (server.client_registries) |*registry| {
        try testing.expect(@intFromPtr(registry) != 0);
    }
}

test "each client registry is independent clone" {
    const config = config_module.Config{
        .max_clients = 1,
        .max_subscribers_per_channel = 1,
        .num_workers = 1,
        .requirepass = null,
        .kv_memory_budget = 1024,
        .temp_arena_size = 1024,
    };

    var server = try Server.initWithConfig(
        testing.allocator,
        "127.0.0.1",
        6381,
        config,
        std.testing.io,
    );
    defer server.deinit();

    // Verify each registry is at a different memory address
    const reg0_ptr = @intFromPtr(&server.client_registries[0]);
    const reg1_ptr = @intFromPtr(&server.client_registries[1]);
    const reg2_ptr = @intFromPtr(&server.client_registries[2]);

    try testing.expect(reg0_ptr != reg1_ptr);
    try testing.expect(reg1_ptr != reg2_ptr);
    try testing.expect(reg0_ptr != reg2_ptr);

    // Verify each registry has commands (from clone)
    for (server.client_registries) |*registry| {
        const ping_cmd = registry.get("PING");
        try testing.expect(ping_cmd != null);
    }
}

test "cloned registry has all commands from original" {
    const config = config_module.Config{
        .max_clients = 1,
        .max_subscribers_per_channel = 1,
        .num_workers = 1,
        .requirepass = null,
        .kv_memory_budget = 1024,
        .temp_arena_size = 1024,
    };

    var server = try Server.initWithConfig(
        testing.allocator,
        "127.0.0.1",
        6382,
        config,
        std.testing.io,
    );
    defer server.deinit();

    // Test that cloned registries have standard commands
    const test_commands = [_][]const u8{
        "PING", "ECHO", "SET", "GET", "CONFIG",
    };

    for (server.client_registries) |*registry| {
        for (test_commands) |cmd_name| {
            const cmd = registry.get(cmd_name);
            try testing.expect(cmd != null);
        }
    }
}

test "client allocation returns unique registry" {
    const config = config_module.Config{
        .max_clients = 1,
        .max_subscribers_per_channel = 1,
        .num_workers = 1,
        .requirepass = null,
        .kv_memory_budget = 1024,
        .temp_arena_size = 1024,
    };

    var server = try Server.initWithConfig(
        testing.allocator,
        "127.0.0.1",
        6383,
        config,
        std.testing.io,
    );
    defer server.deinit();

    // Allocate first client
    const alloc1 = server.allocateClient();
    try testing.expect(alloc1 != null);

    const registry1_ptr = @intFromPtr(alloc1.?.registry);

    // Allocate second client
    const alloc2 = server.allocateClient();
    try testing.expect(alloc2 != null);

    const registry2_ptr = @intFromPtr(alloc2.?.registry);

    // Verify each client got a different registry
    try testing.expect(registry1_ptr != registry2_ptr);

    // Verify both registries work
    try testing.expect(alloc1.?.registry.get("PING") != null);
    try testing.expect(alloc2.?.registry.get("PING") != null);
}
