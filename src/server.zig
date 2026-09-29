const std = @import("std");
const zio = @import("zio");
const Allocator = std.mem.Allocator;
const Client = @import("client.zig").Client;
const ClientMailbox = @import("client_mailbox.zig").ClientMailbox;
const MessageNode = @import("client_mailbox.zig").MessageNode;
const free_message_list = @import("client_mailbox.zig").free_message_list;
const CommandRegistry = @import("./commands/registry.zig").CommandRegistry;
const command_init = @import("./commands/init_registry.zig");
const Reader = @import("./rdb/zdb.zig").Reader;
const Store = @import("store.zig").Store;
const pubsub = @import("./commands/pubsub.zig");
const PubSubContext = pubsub.PubSubContext;
const Config = @import("config.zig");
const KeyValueAllocator = @import("kv_allocator.zig");
const aof = @import("./aof/aof.zig");
const Clock = @import("clock.zig");
const ClientHandle = @import("types.zig").ClientHandle;
const invalid_client_slot_index = @import("types.zig").invalid_client_slot_index;
const Io = std.Io;
const Stream = Io.net.Stream;

const log = std.log.scoped(.server);

const Server = @This();
const mailbox_capacity = 256;

const Value = @import("parser.zig").Value;

const ClientSlotState = enum(u8) {
    free,
    active,
    closing,
};

const ClientSlot = struct {
    generation: std.atomic.Value(u32) = .init(0),
    state: std.atomic.Value(ClientSlotState) = .init(.free),
    disconnect_requested: std.atomic.Value(bool) = .init(false),
    next_free: std.atomic.Value(u32) = .init(invalid_client_slot_index),
    mailbox: ClientMailbox = ClientMailbox.init(mailbox_capacity),
    client: Client = undefined,
};

// Configuration
config: Config,

// Base allocator (only for server initialization)
base_allocator: std.mem.Allocator,

// Network
address: Io.net.IpAddress,
listener: Io.net.Server,
io: Io,

// Fixed allocations (pre-allocated, never freed individually)
client_slots: []ClientSlot,
free_list_head: std.atomic.Value(u64),

// Map of channel_name -> subscriber handles
pubsub_map: std.StringHashMap([]ClientHandle),
pubsub_mutex: std.atomic.Mutex = .unlocked,

// Serializes command execution against the shared store. Client coroutines run
// concurrently on zio's executor threads (executors = .auto, see main.zig), and
// each command executes inline on its own client's executor thread — no store
// thread / cross-thread hand-off. A cooperative (parking) lock is used rather
// than a raw spinlock: command handlers may suspend (AOF file I/O, SAVE), and a
// spinlock held across a suspension would deadlock once every executor thread
// is spinning on it. Uncontended acquisition is a single atomic CAS.
store_lock: zio.Mutex = .init,

// Custom allocator for key-value store with eviction
kv_allocator: KeyValueAllocator,
clock: Clock,
store: Store,
registry: CommandRegistry,
pubsub_context: PubSubContext,

// Metadata
redisVersion: ?[]u8 = undefined,
createdTime: i64,

// AOF logging
aof_writer: aof.Writer,

fn lock_pubsub(self: *Server) void {
    while (!self.pubsub_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

fn unlock_pubsub(self: *Server) void {
    self.pubsub_mutex.unlock();
}

fn pack_free_list_head(index: u32, tag: u32) u64 {
    return (@as(u64, tag) << 32) | index;
}

fn unpack_free_list_head(raw: u64) struct { index: u32, tag: u32 } {
    return .{
        .index = @intCast(raw & std.math.maxInt(u32)),
        .tag = @intCast(raw >> 32),
    };
}

const ClientAllocation = struct {
    handle: ClientHandle,
    slot: *ClientSlot,
};

pub fn init_with_config(
    base_allocator: Allocator,
    host: []const u8,
    port: u16,
    config: Config,
    io: Io,
) !*Server {
    // The server owns self-referencing state (clock updater task, kv store
    // back-pointer, pubsub context), so it must live at a stable address
    // rather than being returned by value from this frame.
    const server = try base_allocator.create(Server);
    errdefer base_allocator.destroy(server);

    server.* = .{
        .config = config,
        .base_allocator = base_allocator,
        .address = try Io.net.IpAddress.parse(host, port),
        .listener = undefined,
        .io = io,
        .client_slots = &.{},
        .free_list_head = .init(0),
        .pubsub_map = .init(base_allocator),
        .kv_allocator = undefined,
        .clock = undefined,
        .store = undefined,
        .registry = undefined,
        .pubsub_context = undefined,
        .redisVersion = undefined,
        .createdTime = 0,
        .aof_writer = undefined,
    };

    server.listener = try server.address.listen(io, .{ .kernel_backlog = 128 * 10, .reuse_address = true });

    // Initialize the KV allocator with eviction support
    server.kv_allocator = try KeyValueAllocator.init(base_allocator, config.kv_memory_budget, config.eviction_policy);

    // Initialize shared clock for the store
    server.clock = Clock.init(io, config.clock_update_ms);
    try server.clock.start();
    errdefer server.clock.deinit();

    // Initialize the single shared store with the KV allocator
    server.store = try Store.init(server.kv_allocator.allocator(), io, &server.clock, .{
        .initial_capacity = config.initial_capacity,
        .eviction_policy = config.eviction_policy,
        .maxmemory_samples = config.maxmemory_samples,
    });

    // Initialize command registry with base allocator (lives for server lifetime)
    server.registry = try command_init.init_registry(base_allocator);

    // Allocate fixed memory pools on heap
    const client_slots = try base_allocator.alloc(ClientSlot, config.max_clients);
    for (client_slots, 0..) |*slot, index| {
        slot.* = .{};
        const next_index: u32 = if (index + 1 < client_slots.len) @intCast(index + 1) else invalid_client_slot_index;
        slot.next_free.store(next_index, .release);
    }
    server.client_slots = client_slots;
    server.free_list_head = .init(pack_free_list_head(if (client_slots.len == 0) invalid_client_slot_index else 0, 0));

    // Use shared clock for timestamp
    const now = server.clock.now().toMilliseconds();
    server.createdTime = now;

    // AOF
    server.aof_writer = try aof.Writer.init(
        base_allocator,
        io,
        config.appendonly,
        config.appendfilename,
        config.dir,
        config.aof_write_buffer_size,
        std.meta.stringToEnum(aof.Writer.FsyncPolicy, config.appendfsync) orelse .everysec,
    );

    // Rebind self-references against the stable, final location.
    server.store.clock = &server.clock;
    server.kv_allocator.attach_store(&server.store);
    server.pubsub_context = PubSubContext.init(server);

    if (config.requires_auth()) {
        log.info("Authentication required", .{});
    } else {
        log.debug("No authentication required", .{});
    }

    // Prefer AOF to RDB
    // Load AOF file if it exists
    // 'true' to be replaced with user option (use aof/rdb on boot)
    if (true) {
        if (aof.Reader.init(base_allocator, &server.store, &server.registry, io, config.dir, config.appendfilename)) |reader_value| {
            var reader = reader_value;
            log.info("Loading AOF into store", .{});
            reader.read() catch |err| {
                log.warn("Failed to read AOF: {s}", .{@errorName(err)});
            };
        } else |err| {
            log.debug("AOF not available: {s}", .{@errorName(err)});
        }
    } else {
        // Load RDB file if it exists
        if (Reader.rdb_file_exists()) {
            if (Reader.init(base_allocator, &server.store)) |reader_value| {
                var reader = reader_value;
                defer reader.deinit();

                if (reader.read_file()) |data| {
                    log.info("Loading RDB into store", .{});
                    server.createdTime = data.ctime;
                } else |err| {
                    log.warn("Failed to read RDB: {s}", .{@errorName(err)});
                }
            } else |err| {
                log.warn("Failed to initialize RDB reader: {s}", .{@errorName(err)});
            }
        }
    }

    log.info("Server initialized - Fixed: {}MB, KV: {}MB", .{
        config.fixed_memory_size() / (1024 * 1024),
        config.kv_memory_budget / (1024 * 1024),
    });

    return server;
}

pub fn deinit(self: *Server) void {
    // Network cleanup
    self.listener.deinit(self.io);

    self.clock.deinit();

    // Store cleanup (uses KV allocator)
    self.store.deinit();

    // Registry cleanup (uses temp arena)
    self.registry.deinit();

    // Clean up pubsub map
    var iterator = self.pubsub_map.iterator();
    while (iterator.next()) |entry| {
        self.base_allocator.free(entry.key_ptr.*);
        self.base_allocator.free(entry.value_ptr.*);
    }
    self.pubsub_map.deinit();

    // Free heap allocated fixed memory pools
    for (self.client_slots) |*slot| {
        slot.mailbox.deinit(self.base_allocator);
    }
    self.base_allocator.free(self.client_slots);

    // Allocator cleanup
    self.kv_allocator.deinit();

    // AOF Deinit
    self.aof_writer.deinit();

    log.info("Server deinitialized - all memory freed", .{});
}

fn execute_locked(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) void {
    // Append to the AOF before replying, like Redis. Runs under the store lock
    // (the single writer to the store), so file I/O is serialized with
    // commands in execution order.
    if (args.len > 0) {
        self.write_aof(args[0].as_slice(), args);
    }

    self.process_command_direct(client, args, response_writer);
}

/// Run one parsed command inline on the calling client coroutine, serialized
/// against other clients by the store lock. The RESP response is written into
/// `response_writer`. Returns after the handler (and any AOF work) finished.
pub fn execute_command(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) void {
    self.store_lock.lock() catch return;
    defer self.store_lock.unlock();

    self.execute_locked(client, args, response_writer);
}

pub fn process_command_direct(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) void {
    self.registry.execute_command(
        response_writer,
        client,
        client.get_current_store(),
        args,
    ) catch |err| {
        log.err("Command execution failed: {s}", .{@errorName(err)});
    };
}

/// Write a command to the AOF file. Runs inline with command execution on the
/// single event-loop thread; the file I/O is async and parks only the running
/// coroutine while it completes.
pub fn write_aof(self: *Server, command_name: []const u8, args: []const Value) void {
    if (!self.aof_writer.enabled) return;
    if (!self.registry.should_write_to_aof(command_name)) return;
    self.aof_writer.write_command(args);
}

// The main server loop. It waits for incoming connections and
// handles each client (one coroutine per connection).
pub fn listen(self: *Server) !void {
    var connection_group: Io.Group = .init;
    defer connection_group.wait(self.io); // Wait for all clients to finish

    while (true) {
        const conn = self.listener.accept(self.io) catch |err| {
            log.err("Error accepting connection: {s}", .{@errorName(err)});
            continue;
        };

        // Handle this client on its own coroutine
        connection_group.async(self.io, handle_connection_async, .{ self, conn });
    }
}

fn handle_connection_async(self: *Server, conn: Stream) void {
    self.handle_connection(conn) catch |err| {
        log.err("Connection error: {s}", .{@errorName(err)});
    };
}

fn handle_connection(self: *Server, conn: Stream) !void {
    // Allocate client from fixed pool
    const allocation = self.allocate_client_slot() orelse {
        log.warn("Maximum client connections reached, rejecting connection", .{});
        conn.close(self.io);
        return;
    };
    const client_slot = allocation.slot;

    // Initialize client in the allocated slot
    client_slot.client = Client.init(
        self.base_allocator,
        conn,
        &self.pubsub_context,
        &self.registry,
        self,
        &self.store,
        allocation.handle,
        &client_slot.mailbox,
        &client_slot.disconnect_requested,
        self.io,
    );
    client_slot.state.store(.active, .release);

    defer {
        _ = self.begin_client_shutdown(allocation.handle, client_slot.client.is_in_pubsub_mode);
        // Always clean up and deallocate when connection ends
        client_slot.client.deinit();
        self.deallocate_client_slot(allocation.handle);
        log.debug("Client {} deallocated from pool", .{client_slot.client.client_id});
    }

    try client_slot.client.handle();
    log.debug("Client {} handled", .{client_slot.client.client_id});
}

fn allocate_client_slot(self: *Server) ?ClientAllocation {
    while (true) {
        const head_raw = self.free_list_head.load(.acquire);
        const head = unpack_free_list_head(head_raw);
        if (head.index == invalid_client_slot_index) return null;

        const slot = &self.client_slots[head.index];
        const next_index = slot.next_free.load(.acquire);
        const next_raw = pack_free_list_head(next_index, head.tag +% 1);

        if (self.free_list_head.cmpxchgWeak(head_raw, next_raw, .acq_rel, .acquire) == null) {
            slot.disconnect_requested.store(false, .release);
            slot.mailbox.open();
            return .{
                .handle = .{
                    .slot_index = head.index,
                    .generation = slot.generation.load(.acquire),
                },
                .slot = slot,
            };
        }
    }
}

fn deallocate_client_slot(self: *Server, handle: ClientHandle) void {
    if (handle.slot_index >= self.client_slots.len) return;

    const slot = &self.client_slots[handle.slot_index];
    if (slot.generation.load(.acquire) != handle.generation) return;

    slot.mailbox.deinit(self.base_allocator);
    slot.disconnect_requested.store(false, .release);
    _ = slot.generation.fetchAdd(1, .acq_rel);
    slot.state.store(.free, .release);
    self.push_free_slot(handle.slot_index);
}

fn push_free_slot(self: *Server, index: u32) void {
    const slot = &self.client_slots[index];
    while (true) {
        const head_raw = self.free_list_head.load(.acquire);
        const head = unpack_free_list_head(head_raw);
        slot.next_free.store(head.index, .release);

        if (self.free_list_head.cmpxchgWeak(head_raw, pack_free_list_head(index, head.tag +% 1), .acq_rel, .acquire) == null) {
            return;
        }
    }
}

fn create_message_node(self: *Server, payload: []const u8) !*MessageNode {
    const owned = try self.base_allocator.dupe(u8, payload);
    errdefer self.base_allocator.free(owned);

    const node = try self.base_allocator.create(MessageNode);
    errdefer self.base_allocator.destroy(node);

    node.* = .{
        .bytes = owned,
        .next = null,
    };
    return node;
}

fn enqueue_to_handle(self: *Server, handle: ClientHandle, payload: []const u8) !void {
    if (handle.slot_index >= self.client_slots.len) return error.StaleHandle;

    const slot = &self.client_slots[handle.slot_index];
    const owned = try self.base_allocator.dupe(u8, payload);
    const node = slot.mailbox.acquire_node(self.base_allocator, owned) catch |err| {
        self.base_allocator.free(owned);
        return err;
    };
    errdefer slot.mailbox.release_node(self.base_allocator, node);

    slot.mailbox.lock_atomic();
    defer slot.mailbox.unlock_atomic();

    const is_active = slot.state.load(.acquire) == .active and
        slot.generation.load(.acquire) == handle.generation and
        !slot.mailbox.closed.load(.acquire);
    if (!is_active) return error.StaleHandle;
    if (slot.mailbox.pending_count >= slot.mailbox.capacity) return error.OutboxFull;

    if (slot.mailbox.tail) |tail| {
        tail.next = node;
    } else {
        slot.mailbox.head = node;
    }
    slot.mailbox.tail = node;
    slot.mailbox.pending_count += 1;
}

fn begin_client_shutdown(self: *Server, handle: ClientHandle, prune_subscriptions: bool) bool {
    if (handle.slot_index >= self.client_slots.len) return false;

    const slot = &self.client_slots[handle.slot_index];
    if (slot.generation.load(.acquire) != handle.generation) return false;

    if (slot.state.cmpxchgStrong(.active, .closing, .acq_rel, .acquire) == null) {
        slot.disconnect_requested.store(true, .release);
        slot.mailbox.close();
        if (prune_subscriptions) {
            self.cleanup_disconnected_pub_sub_client(handle);
        }
        return true;
    }

    return false;
}

fn find_or_create_channel_locked(self: *Server, channel_name: []const u8) !*[]ClientHandle {
    if (self.pubsub_map.getPtr(channel_name)) |ptr| return ptr;

    if (self.pubsub_map.count() >= self.config.max_channels) {
        return error.ChannelLimitReached;
    }

    const owned_key = try self.base_allocator.dupe(u8, channel_name);
    errdefer self.base_allocator.free(owned_key);

    const subscribers = try self.base_allocator.alloc(ClientHandle, 0);
    errdefer self.base_allocator.free(subscribers);

    try self.pubsub_map.put(owned_key, subscribers);
    return self.pubsub_map.getPtr(channel_name).?;
}

fn contains_handle(handles: []const ClientHandle, handle: ClientHandle) bool {
    for (handles) |candidate| {
        if (ClientHandle.eql(candidate, handle)) return true;
    }
    return false;
}

fn remove_handle_from_slice(self: *Server, current_subscribers: []const ClientHandle, handle: ClientHandle) !?[]ClientHandle {
    var remove_index: ?usize = null;
    for (current_subscribers, 0..) |existing_handle, i| {
        if (ClientHandle.eql(existing_handle, handle)) {
            remove_index = i;
            break;
        }
    }

    const index = remove_index orelse return null;
    if (current_subscribers.len == 1) return current_subscribers[0..0];

    const new_subscribers = try self.base_allocator.alloc(ClientHandle, current_subscribers.len - 1);
    @memcpy(new_subscribers[0..index], current_subscribers[0..index]);
    if (index < current_subscribers.len - 1) {
        @memcpy(new_subscribers[index..], current_subscribers[index + 1 ..]);
    }
    return new_subscribers;
}

fn prune_handles_from_channel_locked(self: *Server, channel_name: []const u8, handles: []const ClientHandle) !void {
    const current_subscribers = self.pubsub_map.get(channel_name) orelse return;

    var kept_count: usize = 0;
    for (current_subscribers) |existing_handle| {
        if (!contains_handle(handles, existing_handle)) kept_count += 1;
    }

    if (kept_count == current_subscribers.len) return;
    if (kept_count == 0) {
        if (self.pubsub_map.fetchRemove(channel_name)) |removed| {
            self.base_allocator.free(removed.key);
            self.base_allocator.free(removed.value);
        }
        return;
    }

    const next_subscribers = try self.base_allocator.alloc(ClientHandle, kept_count);
    var next_index: usize = 0;
    for (current_subscribers) |existing_handle| {
        if (contains_handle(handles, existing_handle)) continue;
        next_subscribers[next_index] = existing_handle;
        next_index += 1;
    }

    self.base_allocator.free(current_subscribers);
    self.pubsub_map.getPtr(channel_name).?.* = next_subscribers;
}

fn prune_handles_from_channel(self: *Server, channel_name: []const u8, handles: []const ClientHandle) !void {
    if (handles.len == 0) return;

    self.lock_pubsub();
    defer self.unlock_pubsub();

    try self.prune_handles_from_channel_locked(channel_name, handles);
}

pub fn subscribe_to_channel(self: *Server, channel_name: []const u8, handle: ClientHandle) !void {
    self.lock_pubsub();
    defer self.unlock_pubsub();

    const subscribers_ptr = try self.find_or_create_channel_locked(channel_name);
    const current_subscribers = subscribers_ptr.*;

    for (current_subscribers) |existing_handle| {
        if (ClientHandle.eql(existing_handle, handle)) return;
    }

    if (current_subscribers.len >= self.config.max_subscribers_per_channel) {
        return error.ChannelFull;
    }

    const new_subscribers = try self.base_allocator.realloc(current_subscribers, current_subscribers.len + 1);
    new_subscribers[new_subscribers.len - 1] = handle;
    subscribers_ptr.* = new_subscribers;
}

pub fn unsubscribe_from_channel(self: *Server, channel_name: []const u8, handle: ClientHandle) !void {
    self.lock_pubsub();
    defer self.unlock_pubsub();

    const current_subscribers = self.pubsub_map.get(channel_name) orelse return;
    const new_subscribers = try self.remove_handle_from_slice(current_subscribers, handle) orelse return;

    if (new_subscribers.len == 0) {
        if (self.pubsub_map.fetchRemove(channel_name)) |removed| {
            self.base_allocator.free(removed.key);
            self.base_allocator.free(removed.value);
        }
        return;
    }

    self.base_allocator.free(current_subscribers);
    self.pubsub_map.getPtr(channel_name).?.* = new_subscribers;
}

pub fn publish_to_channel(self: *Server, channel_name: []const u8, payload: []const u8) !usize {
    self.lock_pubsub();
    const current_subscribers = self.pubsub_map.get(channel_name) orelse {
        self.unlock_pubsub();
        return 0;
    };
    const snapshot = try self.base_allocator.dupe(ClientHandle, current_subscribers);
    self.unlock_pubsub();
    defer self.base_allocator.free(snapshot);

    var stale_handles: std.ArrayList(ClientHandle) = .empty;
    defer stale_handles.deinit(self.base_allocator);

    var messages_sent: usize = 0;
    for (snapshot) |handle| {
        if (self.enqueue_to_handle(handle, payload)) |_| {
            messages_sent += 1;
        } else |err| switch (err) {
            error.StaleHandle => try stale_handles.append(self.base_allocator, handle),
            error.OutboxFull => {
                _ = self.begin_client_shutdown(handle, true);
                try stale_handles.append(self.base_allocator, handle);
            },
            else => return err,
        }
    }

    if (stale_handles.items.len > 0) {
        try self.prune_handles_from_channel(channel_name, stale_handles.items);
    }

    return messages_sent;
}

pub fn cleanup_disconnected_pub_sub_client(self: *Server, handle: ClientHandle) void {
    self.lock_pubsub();
    defer self.unlock_pubsub();

    var empty_channels: std.ArrayList([]const u8) = .empty;
    defer empty_channels.deinit(self.base_allocator);

    var channel_iterator = self.pubsub_map.iterator();
    while (channel_iterator.next()) |entry| {
        const updated_subscribers = self.remove_handle_from_slice(entry.value_ptr.*, handle) catch |err| {
            log.warn("Failed to unsubscribe slot {} from channel {s}: {s}", .{
                handle.slot_index,
                entry.key_ptr.*,
                @errorName(err),
            });
            continue;
        } orelse continue;

        if (updated_subscribers.len == 0) {
            empty_channels.append(self.base_allocator, entry.key_ptr.*) catch |err| {
                log.warn("Failed to queue pubsub channel cleanup for slot {}: {s}", .{
                    handle.slot_index,
                    @errorName(err),
                });
            };
            continue;
        }

        self.base_allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = updated_subscribers;
    }

    for (empty_channels.items) |channel_name| {
        if (self.pubsub_map.fetchRemove(channel_name)) |removed| {
            self.base_allocator.free(removed.key);
            self.base_allocator.free(removed.value);
        }
    }
}

// Memory statistics
pub fn get_memory_stats(self: *Server) Config.MemoryStats {
    const fixed_size = self.config.fixed_memory_size();
    const total_budget = self.config.total_memory_budget();
    return Config.MemoryStats{
        .fixed_memory_used = fixed_size,
        .kv_memory_used = self.kv_allocator.get_memory_usage(),
        .total_allocated = fixed_size + self.kv_allocator.get_memory_usage(),
        .total_budget = total_budget,
    };
}
pub fn get_channel_count(self: *Server) u32 {
    self.lock_pubsub();
    defer self.unlock_pubsub();
    return @intCast(self.pubsub_map.count());
}

const testing = std.testing;

fn init_test_server(allocator: Allocator, max_clients: u32) !Server {
    const client_slots = try allocator.alloc(ClientSlot, max_clients);
    for (client_slots, 0..) |*slot, index| {
        slot.* = .{};
        const next_index: u32 = if (index + 1 < client_slots.len) @intCast(index + 1) else invalid_client_slot_index;
        slot.next_free.store(next_index, .release);
    }

    var server = Server{
        .config = .{
            .max_clients = max_clients,
            .max_channels = 16,
            .max_subscribers_per_channel = 16,
        },
        .base_allocator = allocator,
        .address = undefined,
        .listener = undefined,
        .io = testing.io,
        .client_slots = client_slots,
        .free_list_head = .init(pack_free_list_head(if (client_slots.len == 0) invalid_client_slot_index else 0, 0)),
        .pubsub_map = .init(allocator),
        .pubsub_mutex = .unlocked,
        .kv_allocator = undefined,
        .clock = Clock.init(testing.io, 0),
        .store = undefined,
        .registry = undefined,
        .pubsub_context = undefined,
        .redisVersion = null,
        .createdTime = 0,
        .aof_writer = undefined,
    };
    server.pubsub_context = PubSubContext.init(&server);
    return server;
}

fn deinit_test_server(server: *Server) void {
    server.clock.deinit();

    var iterator = server.pubsub_map.iterator();
    while (iterator.next()) |entry| {
        server.base_allocator.free(entry.key_ptr.*);
        server.base_allocator.free(entry.value_ptr.*);
    }
    server.pubsub_map.deinit();

    for (server.client_slots) |*slot| {
        slot.mailbox.deinit(server.base_allocator);
    }
    server.base_allocator.free(server.client_slots);
}

test "Server reuses freed slots with a new generation" {
    var server = try init_test_server(testing.allocator, 2);
    defer deinit_test_server(&server);

    const first = server.allocate_client_slot().?;
    try testing.expectEqual(@as(u32, 0), first.handle.slot_index);
    try testing.expectEqual(@as(u32, 0), first.handle.generation);

    server.deallocate_client_slot(first.handle);

    const second = server.allocate_client_slot().?;
    try testing.expectEqual(@as(u32, 0), second.handle.slot_index);
    try testing.expectEqual(@as(u32, 1), second.handle.generation);
}

test "Server publish_to_channel enqueues active subscribers and prunes stale handles" {
    var server = try init_test_server(testing.allocator, 2);
    defer deinit_test_server(&server);

    const active = server.allocate_client_slot().?;
    active.slot.state.store(.active, .release);

    try server.subscribe_to_channel("news", active.handle);
    try server.subscribe_to_channel("news", .{ .slot_index = 1, .generation = 99 });

    const delivered = try server.publish_to_channel("news", "payload");
    try testing.expectEqual(@as(usize, 1), delivered);

    const queued = active.slot.mailbox.take_all();
    defer free_message_list(server.base_allocator, queued);

    try testing.expect(queued != null);
    try testing.expectEqualStrings("payload", queued.?.bytes);

    server.lock_pubsub();
    defer server.unlock_pubsub();

    const subscribers = server.pubsub_map.get("news").?;
    try testing.expectEqual(@as(usize, 1), subscribers.len);
    try testing.expect(ClientHandle.eql(active.handle, subscribers[0]));
}
