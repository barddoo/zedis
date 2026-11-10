const std = @import("std");
const zio = @import("zio");
const Allocator = std.mem.Allocator;
const client_module = @import("client.zig");
const Client = client_module.Client;
const ClientMailbox = @import("../util/client_mailbox.zig").ClientMailbox;
const MessageNode = @import("../util/client_mailbox.zig").MessageNode;
const free_message_list = @import("../util/client_mailbox.zig").free_message_list;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;
const command_init = @import("../commands/init_registry.zig");
const Reader = @import("../persistence/zdb.zig").Reader;
const Store = @import("../storage/store.zig").Store;
const pubsub = @import("../commands/pubsub.zig");
const PubSubContext = pubsub.PubSubContext;
const Config = @import("config.zig");
const KeyValueAllocator = @import("../storage/kv_allocator.zig");
const aof = @import("../persistence/aof.zig");
const Clock = @import("clock.zig");
const Stats = @import("stats.zig");
const ServerStats = Stats.ServerStats;
const SlowLog = Stats.SlowLog;
const LatencyMonitor = Stats.LatencyMonitor;
const resp = @import("../protocol/resp.zig");
const ClientHandle = @import("../util/types.zig").ClientHandle;
const invalid_client_slot_index = @import("../util/types.zig").invalid_client_slot_index;
const tls_mod = @import("tls.zig");
const Transport = client_module.Transport;
const Io = std.Io;
const Stream = Io.net.Stream;

const log = std.log.scoped(.server);

const Server = @This();
const mailbox_capacity = 256;

pub const server_version = "0.2.1";

const Value = @import("../protocol/parser.zig").Value;

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
    /// Signaled by publishers; wakes the client's delivery coroutine.
    mailbox_event: zio.Event = .init,
    client: Client = undefined,
};

// Configuration
config: Config,

// Base allocator (only for server initialization)
base_allocator: std.mem.Allocator,

// Network
address: Io.net.IpAddress,
/// Plaintext listener. Null when `port 0` restricts the server to TLS.
listener: ?Io.net.Server,
/// TLS listener. Null unless `tls-port` is set.
tls_listener: ?Io.net.Server,
tls: ?*tls_mod.Server,
io: Io,

// Fixed allocations (pre-allocated, never freed individually)
client_slots: []ClientSlot,
free_list_head: std.atomic.Value(u64),

// Map of channel_name -> subscriber handles
pubsub_map: std.StringHashMap([]ClientHandle),
pubsub_mutex: std.atomic.Mutex = .unlocked,

// Command execution needs no store lock: the zio runtime always runs exactly
// one executor (main.zig), and command handlers are written so they never
// suspend (SAVE uses blocking I/O; AOF queueing uses a spinlock). A coroutine
// therefore runs a command to completion before another client coroutine can
// run, and no one else touches the store from another thread.

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
/// Parsed `auto-aof-rewrite-min-size`, so the per-write size check stays cheap.
aof_rewrite_min_size: u64 = 0,

// Observability
stats: ServerStats,
slowlog: SlowLog,
latency: LatencyMonitor,
run_id: [40]u8,

// Shutdown
shutdown_requested: std.atomic.Value(bool) = .init(false),

/// Deadline for the read-only command currently running, or null when
/// `command-timeout-ms` is disabled. Shared with the store so StoreHandler
/// commands can check it without a server pointer.
command_deadline_ns: ?u64 = null,

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

fn fillRunId(out: *[40]u8, io: Io) void {
    var bytes: [20]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(Stats.nowNs(io));
    prng.random().bytes(&bytes);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0x0f];
    }
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
        .listener = null,
        .tls_listener = null,
        .tls = null,
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
        .stats = undefined,
        .slowlog = undefined,
        .latency = .{},
        .run_id = undefined,
    };
    errdefer server.deinitNetwork();

    if (config.tls_enabled()) {
        server.tls = try tls_mod.Server.create(base_allocator, .{
            .cert_file = config.tls_cert_file,
            .key_file = config.tls_key_file,
            .ca_file = config.tls_ca_cert_file,
            .auth_clients = switch (config.tls_auth_clients) {
                .no => .no,
                .optional => .optional,
                .yes => .required,
            },
            .protocols = config.tls_protocols,
        });

        const tls_address = try Io.net.IpAddress.parse(host, config.tls_port);
        server.tls_listener = try tls_address.listen(io, .{ .kernel_backlog = 128 * 10, .reuse_address = true });
    }

    if (port != 0) {
        server.listener = try server.address.listen(io, .{ .kernel_backlog = 128 * 10, .reuse_address = true });
    }
    if (server.listener == null and server.tls_listener == null) return error.NoListener;

    // Initialize the KV allocator with eviction support
    server.kv_allocator = try KeyValueAllocator.init(base_allocator, config.kv_memory_budget, config.eviction_policy);

    // Initialize shared clock for the store
    server.clock = Clock.init(io, config.clock_update_ms);
    try server.clock.start();
    errdefer server.clock.deinit();

    server.store = try Store.init(server.kv_allocator.allocator(), io, &server.clock, .{
        .initial_capacity = config.initial_capacity,
        .eviction_policy = config.eviction_policy,
        .maxmemory_samples = config.maxmemory_samples,
    });

    server.registry = try command_init.init_registry(base_allocator);

    server.stats = ServerStats.init(base_allocator, io);
    errdefer server.stats.deinit();
    server.slowlog = try SlowLog.init(base_allocator, config.slowlog_max_len);
    errdefer server.slowlog.deinit();
    server.slowlog.threshold_us = config.slowlog_log_slower_than;
    server.latency.threshold_ms = config.latency_monitor_threshold;
    fillRunId(&server.run_id, io);

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

    // Rebind self-references against the stable, final location.
    server.store.clock = &server.clock;
    server.kv_allocator.attach_store(&server.store);
    server.pubsub_context = PubSubContext.init(server);

    if (config.requires_auth()) {
        log.info("Authentication required", .{});
    } else {
        log.debug("No authentication required", .{});
    }

    // Redis ignores maxmemory while loading a dataset; the budget is applied
    // again at the next command. Besides matching Redis, this keeps eviction
    // from running while the loader holds pointers into the store.
    server.kv_allocator.begin_command();
    defer server.kv_allocator.end_command();

    // Prefer AOF to RDB
    // Load AOF file if it exists
    // 'true' to be replaced with user option (use aof/rdb on boot)
    if (true) {
        const load_options: aof.LoadOptions = .{
            .load_truncated = config.aof_load_truncated,
            .load_broken = config.aof_load_broken,
            .broken_max_size = config.aof_load_broken_max_size,
            // Only an AOF this server will keep appending to may be edited.
            .repair = config.appendonly,
        };
        if (aof.Reader.init(base_allocator, &server.store, &server.registry, io, config.dir, config.appendfilename, load_options)) |reader_value| {
            var reader = reader_value;
            log.info("Loading AOF into store", .{});
            reader.read() catch |err| {
                log.err("Refusing to start: the AOF could not be loaded safely ({s})", .{@errorName(err)});
                return err;
            };
        } else |err| switch (err) {
            error.FileNotFound => log.debug("No AOF to load", .{}),
            else => {
                log.err("Refusing to start: cannot open the AOF ({s})", .{@errorName(err)});
                return err;
            },
        }
    } else {
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

    // After loading: the writer starts appending at the file's length, which a
    // repaired AOF has just changed.
    server.aof_writer = try aof.Writer.init(
        base_allocator,
        io,
        config.appendonly,
        config.appendfilename,
        config.dir,
        std.meta.stringToEnum(aof.Writer.FsyncPolicy, config.appendfsync) orelse .everysec,
    );
    server.aof_rewrite_min_size = try Config.parse_memory_size(config.auto_aof_rewrite_min_size);

    log.info("Server initialized - Fixed: {}MB, KV: {}MB", .{
        config.fixed_memory_size() / (1024 * 1024),
        config.kv_memory_budget / (1024 * 1024),
    });

    return server;
}

pub fn deinit(self: *Server) void {
    // Network cleanup
    self.deinitNetwork();

    self.clock.deinit();

    self.store.deinit();

    // Registry cleanup (uses temp arena)
    self.registry.deinit();

    self.slowlog.deinit();
    self.stats.deinit();

    var iterator = self.pubsub_map.iterator();
    while (iterator.next()) |entry| {
        self.base_allocator.free(entry.key_ptr.*);
        self.base_allocator.free(entry.value_ptr.*);
    }
    self.pubsub_map.deinit();

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

fn deinitNetwork(self: *Server) void {
    if (self.listener) |*listener| listener.deinit(self.io);
    if (self.tls_listener) |*listener| listener.deinit(self.io);
    if (self.tls) |tls| tls.destroy();
    self.listener = null;
    self.tls_listener = null;
    self.tls = null;
}

/// How a command reaches the AOF.
const AofLogging = enum {
    none,
    /// Logged as received, before it executes.
    verbatim,
    /// Sets a relative TTL (EXPIRE, PEXPIRE, SETEX). Logged after it executes as the
    /// state it produced, with the TTL as an absolute PEXPIREAT like Redis, so
    /// replaying the AOF later doesn't restart the countdown.
    absolute_ttl,
};

fn aof_logging(self: *Server, command_name: []const u8) AofLogging {
    if (!self.aof_writer.enabled) return .none;
    if (std.ascii.eqlIgnoreCase(command_name, "EXPIRE") or
        std.ascii.eqlIgnoreCase(command_name, "PEXPIRE") or
        std.ascii.eqlIgnoreCase(command_name, "SETEX"))
    {
        return .absolute_ttl;
    }
    return if (self.registry.should_write_to_aof(command_name)) .verbatim else .none;
}

/// Redis' `processCommand` memory admission: evict down to the budget before
/// the command runs, and reject `CMD_DENYOOM` commands with `-OOM` when that
/// isn't possible. Returns false when the command was rejected and a reply was
/// already written.
fn memory_gate(self: *Server, client: *Client, args: []const Value, writer: *std.Io.Writer) bool {
    if (args.len == 0) return true;

    var buf: [32]u8 = undefined;
    const command_name = args[0].as_slice();
    if (command_name.len > buf.len) return true;
    const upper_name = std.ascii.upperString(&buf, command_name);

    // Unknown commands and bad arity get the registry's own error.
    const info = self.registry.get(upper_name) orelse return true;
    if (args.len < info.min_args) return true;
    if (info.max_args) |max_args| {
        if (args.len > max_args) return true;
    }

    // Let the registry answer NOAUTH for unauthenticated clients.
    if (!client.is_authenticated() and
        !std.mem.eql(u8, upper_name, "AUTH") and
        !std.mem.eql(u8, upper_name, "PING"))
    {
        return true;
    }

    if (self.kv_allocator.enforce_budget()) return true;
    if (!info.denyoom) return true;

    resp.write_error(writer, CommandRegistry.oom_error_message) catch {};
    return false;
}

pub fn execute_locked(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) bool {
    if (!self.memory_gate(client, args, response_writer)) return false;

    // Like Redis' maxmemory, the budget is soft while the command runs: it may
    // overshoot and is enforced at the next command boundary. Evicting here
    // would be unsafe, because handlers hold pointers into the store.
    self.kv_allocator.begin_command();
    defer self.kv_allocator.end_command();

    if (args.len > 0 and self.registry.should_write_to_aof(args[0].as_slice())) {
        self.stats.rdb_changes_since_last_save +%= 1;
    }

    // AOF entries are queued during command execution, so the AOF order
    // matches execution order.
    const logging: AofLogging = if (args.len > 0) self.aof_logging(args[0].as_slice()) else .none;
    if (logging != .none) {
        // Like Redis' MISCONF: refuse writes the AOF can't persist.
        if (self.aof_writer.failure()) |failure| {
            failure.write_error(response_writer) catch {};
            return false;
        }
    }
    if (logging == .verbatim) client.aof_end = self.aof_writer.write_command(args);

    // EXPIRE with a non-positive TTL deletes the key; remember whether it
    // existed so that is logged as a DEL.
    const existed = logging == .absolute_ttl and args.len > 1 and args[1].as_slice().len > 0 and
        self.store.exists(args[1].as_slice());

    const ok = self.process_command_direct(client, args, response_writer);

    if (logging == .absolute_ttl) self.log_absolute_ttl(client, args, existed);
    if (logging != .none) self.maybe_rewrite_aof();
    return ok;
}

/// Starts rewriting the AOF on a background thread; see `aof.Writer.start_rewrite`.
pub fn start_aof_rewrite(self: *Server) !void {
    try self.aof_writer.start_rewrite(&self.registry);
}

/// Starts a background AOF rewrite once the file has outgrown its last one,
/// after the command that grew it has run and been logged.
fn maybe_rewrite_aof(self: *Server) void {
    const now_s = @divTrunc(self.clock.now().toMilliseconds(), 1000);
    if (!self.aof_writer.rewrite_due(self.aof_rewrite_min_size, self.config.auto_aof_rewrite_percentage, now_s)) return;

    log.info("AOF is {d} bytes; rewriting it in the background", .{self.aof_writer.currentSize()});
    self.start_aof_rewrite() catch |err| log.warn("Could not start an AOF rewrite: {s}", .{@errorName(err)});
}

/// Logs the state an EXPIRE or SETEX left behind: `SET key value` for SETEX,
/// then `PEXPIREAT key <expiry ms>` if the key has a TTL, or `DEL key` if
/// EXPIRE deleted it.
fn log_absolute_ttl(self: *Server, client: *Client, args: []const Value, existed: bool) void {
    if (args.len < 3 or args[1].as_slice().len == 0) return;
    const key = args[1].as_slice();

    if (std.ascii.eqlIgnoreCase(args[0].as_slice(), "SETEX")) {
        // Only log a SETEX that took effect, i.e. its value is now stored.
        if (args.len != 4 or !self.stored_string_equals(key, args[3].as_slice())) return;
        client.aof_end = self.aof_writer.write_command(&[_]Value{ .{ .data = "SET" }, args[1], args[3] });
    } else if (!self.store.exists(key)) {
        if (existed) client.aof_end = self.aof_writer.write_command(&[_]Value{ .{ .data = "DEL" }, args[1] });
        return;
    }

    const expires_at = self.store.get_ttl(key) orelse return;
    var buf: [20]u8 = undefined;
    const at = std.fmt.bufPrint(&buf, "{d}", .{expires_at}) catch unreachable;
    client.aof_end = self.aof_writer.write_command(&[_]Value{ .{ .data = "PEXPIREAT" }, args[1], .{ .data = at } });
}

fn stored_string_equals(self: *Server, key: []const u8, expected: []const u8) bool {
    const object = self.store.get(key) orelse return false;
    return switch (object.value) {
        .string => |s| std.mem.eql(u8, s, expected),
        .short_string => |ss| std.mem.eql(u8, ss.as_slice(), expected),
        else => false,
    };
}

/// Run one parsed command inline on the calling client coroutine. With the
/// single executor and non-suspending handlers, this is serialized against
/// other clients without a lock. The RESP response is written into
/// `response_writer`. Returns after the handler (and any AOF work) finished.
pub fn execute_command(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) void {
    const start_ns = Stats.nowNs(self.io);

    // Inside MULTI, everything except the transaction controls is buffered.
    // Controls still run normally so they keep their Redis errors (nested
    // MULTI, EXEC without MULTI, ...).
    if (client.transaction != null and args.len > 0 and !isTransactionControl(args[0].as_slice())) {
        // Recorded when EXEC actually runs it, like Redis; queueing is not
        // execution.
        self.queueTransactionCommand(client, args, response_writer);
        return;
    }

    // A deadline only makes sense for read-only commands: aborting a write
    // mid-handler would leave a partially applied change.
    const previous_deadline = self.command_deadline_ns;
    if (self.config.command_timeout_ms > 0 and self.isReadOnlyCommand(args)) {
        const deadline = Stats.nowNs(self.io) + self.config.command_timeout_ms * 1_000_000;
        self.command_deadline_ns = deadline;
        self.store.command_deadline_ns = deadline;
    } else {
        self.command_deadline_ns = null;
        self.store.command_deadline_ns = null;
    }
    defer {
        self.command_deadline_ns = previous_deadline;
        self.store.command_deadline_ns = previous_deadline;
    }

    const ok = self.execute_locked(client, args, response_writer);
    self.recordCommandMetrics(client, args, start_ns, ok);
}

fn isReadOnlyCommand(self: *Server, args: []const Value) bool {
    if (args.len == 0) return false;
    const name = args[0].as_slice();
    var buffer: [32]u8 = undefined;
    if (name.len > buffer.len) return false;
    const upper = std.ascii.upperString(&buffer, name);
    const info = self.registry.get(upper) orelse return false;
    return !info.write_to_aof;
}

fn recordCommandMetrics(self: *Server, client: *Client, args: []const Value, start_ns: u64, ok: bool) void {
    const duration_ns = Stats.nowNs(self.io) -| start_ns;
    const name = self.statsCommandName(args);
    self.stats.recordCommand(self.io, name, duration_ns, !ok);

    const now_ms = self.clock.now().toMilliseconds();
    var addr_buffer: [64]u8 = undefined;
    const addr = client.peerAddress(&addr_buffer);
    self.slowlog.maybeRecord(args, duration_ns / 1000, addr, client.name orelse "", @divTrunc(now_ms, 1000));
    self.latency.record("command", @divTrunc(now_ms, 1000), duration_ns / 1_000_000);
}

fn statsCommandName(self: *Server, args: []const Value) []const u8 {
    if (args.len == 0) return "unknown";
    const name = args[0].as_slice();
    var buffer: [32]u8 = undefined;
    if (name.len > buffer.len) return "unknown";
    const upper = std.ascii.upperString(&buffer, name);
    if (self.registry.get(upper)) |info| return info.name;
    return "unknown";
}

fn isTransactionControl(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "MULTI") or
        std.ascii.eqlIgnoreCase(name, "EXEC") or
        std.ascii.eqlIgnoreCase(name, "DISCARD");
}

fn queueTransactionCommand(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) void {
    const transaction = client.transaction.?;
    const name = args[0].as_slice();

    var buf: [32]u8 = undefined;
    if (name.len > buf.len) {
        transaction.dirty = true;
        response_writer.print("-ERR unknown command '{s}'\r\n", .{name}) catch {};
        return;
    }

    const upper_name = std.ascii.upperString(&buf, name);
    const info = self.registry.get(upper_name) orelse {
        transaction.dirty = true;
        response_writer.print("-ERR unknown command '{s}'\r\n", .{name}) catch {};
        return;
    };

    if (args.len < info.min_args or (info.max_args != null and args.len > info.max_args.?)) {
        transaction.dirty = true;
        response_writer.print("-ERR wrong number of arguments for '{s}' command\r\n", .{name}) catch {};
        return;
    }

    client.queueTransactionCommand(args) catch |err| {
        transaction.dirty = true;
        const message = if (err == error.OutOfMemory)
            CommandRegistry.oom_error_message
        else
            "ERR while queueing command";
        resp.write_error(response_writer, message) catch {};
        return;
    };

    resp.write_simple_string(response_writer, "QUEUED") catch {};
}

pub fn process_command_direct(self: *Server, client: *Client, args: []const Value, response_writer: *std.Io.Writer) bool {
    return self.registry.execute_command(
        response_writer,
        client,
        client.get_current_store(),
        args,
    ) catch |err| {
        log.err("Command execution failed: {s}", .{@errorName(err)});
        return false;
    };
}

// The main server loop. It waits for incoming connections and
// handles each client (one coroutine per connection).
pub fn listen(self: *Server) !void {
    var connection_group: Io.Group = .init;
    defer connection_group.await(self.io) catch {}; // Wait for all clients to finish

    // zio delivers signals as awaitable events. One watcher per signal lets
    // either SIGINT or SIGTERM request shutdown; cancelling this group on
    // return stops the waiters and restores the previous OS handlers.
    var signal_group: Io.Group = .init;
    defer signal_group.cancel(self.io);
    signal_group.async(self.io, watchSignal, .{ self, zio.SignalKind.interrupt });
    signal_group.async(self.io, watchSignal, .{ self, zio.SignalKind.terminate });

    var accept_group: Io.Group = .init;
    defer accept_group.cancel(self.io);

    if (self.tls_listener) |*tls_listener| {
        accept_group.async(self.io, acceptLoop, .{ self, tls_listener, true, &connection_group });
    }
    if (self.listener) |*listener| {
        accept_group.async(self.io, acceptLoop, .{ self, listener, false, &connection_group });
    }
    if (self.listener == null and self.tls_listener == null) return error.NoListener;

    // Stay parked until a signal or SHUTDOWN requests it. Cancelling the
    // accept coroutines is what wakes a blocked accept; closing the listener
    // here would race `deinitNetwork`.
    while (!self.shutdown_requested.load(.acquire)) {
        zio.sleep(.fromMilliseconds(200)) catch return;
    }
    accept_group.cancel(self.io);
    accept_group.await(self.io) catch {};
}

fn watchSignal(self: *Server, kind: zio.SignalKind) void {
    var signal = zio.Signal.init(kind) catch return;
    defer signal.deinit();

    signal.wait() catch return;
    log.info("Received {s}, shutting down", .{@tagName(kind)});
    self.requestShutdown(null);
}

/// Stops accepting and asks every client to leave. The caller's handle is
/// spared the socket shutdown so its final reply can still be flushed; it
/// closes itself once `disconnect_requested` is seen.
pub fn requestShutdown(self: *Server, initiator: ?ClientHandle) void {
    self.shutdown_requested.store(true, .release);
    for (self.client_slots, 0..) |*slot, index| {
        if (slot.state.load(.acquire) != .active) continue;
        slot.disconnect_requested.store(true, .release);
        const is_initiator = if (initiator) |handle| handle.slot_index == index else false;
        if (!is_initiator) slot.client.connection.shutdown(self.io);
    }
}

fn acceptLoop(self: *Server, listener: *Io.net.Server, use_tls: bool, group: *Io.Group) !void {
    while (!self.shutdown_requested.load(.acquire)) {
        const stream = listener.accept(self.io) catch |err| {
            if (self.shutdown_requested.load(.acquire) or err == error.Canceled or err == error.SocketNotListening) {
                return;
            }
            log.err("Error accepting connection: {s}", .{@errorName(err)});
            continue;
        };

        if (self.shutdown_requested.load(.acquire)) {
            stream.close(self.io);
            return;
        }

        if (use_tls) {
            group.async(self.io, handle_tls_connection_async, .{ self, stream });
        } else {
            group.async(self.io, handle_connection_async, .{ self, stream });
        }
    }
}

fn handle_connection_async(self: *Server, stream: Stream) void {
    self.handle_connection(.{ .plain = stream }) catch |err| {
        log.err("Connection error: {s}", .{@errorName(err)});
    };
}

fn handle_tls_connection_async(self: *Server, stream: Stream) void {
    const tls = self.tls orelse {
        stream.close(self.io);
        return;
    };
    const connection = tls_mod.Connection.accept(stream, self.io, tls) catch |err| {
        log.warn("TLS handshake failed: {s}", .{@errorName(err)});
        stream.close(self.io);
        return;
    };

    self.handle_connection(.{ .tls = .{ .stream = stream, .connection = connection } }) catch |err| {
        log.err("TLS connection error: {s}", .{@errorName(err)});
    };
}

fn handle_connection(self: *Server, transport: Transport) !void {
    const allocation = self.allocate_client_slot() orelse {
        self.stats.rejected_connections +%= 1;
        log.warn("Maximum client connections reached, rejecting connection", .{});
        transport.close(self.io);
        return;
    };
    const client_slot = allocation.slot;

    client_slot.client = Client.init(
        self.base_allocator,
        transport,
        &self.pubsub_context,
        &self.registry,
        self,
        &self.store,
        allocation.handle,
        &client_slot.mailbox,
        &client_slot.mailbox_event,
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
    slot.mailbox_event.set();
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

/// Returns true when the client was not already subscribed.
pub fn subscribe_to_channel(self: *Server, channel_name: []const u8, handle: ClientHandle) !bool {
    self.lock_pubsub();
    defer self.unlock_pubsub();

    const subscribers_ptr = try self.find_or_create_channel_locked(channel_name);
    const current_subscribers = subscribers_ptr.*;

    for (current_subscribers) |existing_handle| {
        if (ClientHandle.eql(existing_handle, handle)) return false;
    }

    if (current_subscribers.len >= self.config.max_subscribers_per_channel) {
        return error.ChannelFull;
    }

    const new_subscribers = try self.base_allocator.realloc(current_subscribers, current_subscribers.len + 1);
    new_subscribers[new_subscribers.len - 1] = handle;
    subscribers_ptr.* = new_subscribers;
    return true;
}

/// Returns true when the client was actually removed from the channel.
pub fn unsubscribe_from_channel(self: *Server, channel_name: []const u8, handle: ClientHandle) !bool {
    self.lock_pubsub();
    defer self.unlock_pubsub();

    const current_subscribers = self.pubsub_map.get(channel_name) orelse return false;
    const new_subscribers = try self.remove_handle_from_slice(current_subscribers, handle) orelse return false;

    if (new_subscribers.len == 0) {
        if (self.pubsub_map.fetchRemove(channel_name)) |removed| {
            self.base_allocator.free(removed.key);
            self.base_allocator.free(removed.value);
        }
        return true;
    }

    self.base_allocator.free(current_subscribers);
    self.pubsub_map.getPtr(channel_name).?.* = new_subscribers;
    return true;
}

/// Removes a client from every channel. Returns the channel names it was
/// subscribed to, owned by `allocator` (caller frees each name and the slice).
pub fn unsubscribe_all(self: *Server, handle: ClientHandle, allocator: Allocator) ![][]u8 {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    {
        self.lock_pubsub();
        defer self.unlock_pubsub();

        var iterator = self.pubsub_map.iterator();
        while (iterator.next()) |entry| {
            if (!contains_handle(entry.value_ptr.*, handle)) continue;
            const copy = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(copy);
            try names.append(allocator, copy);
        }
    }

    for (names.items) |name| {
        _ = self.unsubscribe_from_channel(name, handle) catch {};
    }

    return try names.toOwnedSlice(allocator);
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

/// Test-only minimal server (no listener, store, registry or AOF). Returned by
/// value, so `pubsub_context` is intentionally left unbound: bind it after the
/// value has its final address if a test needs it.
fn init_test_server(allocator: Allocator, max_clients: u32) !Server {
    const client_slots = try allocator.alloc(ClientSlot, max_clients);
    for (client_slots, 0..) |*slot, index| {
        slot.* = .{};
        const next_index: u32 = if (index + 1 < client_slots.len) @intCast(index + 1) else invalid_client_slot_index;
        slot.next_free.store(next_index, .release);
    }

    const slowlog = try SlowLog.init(allocator, 0);
    const server = Server{
        .config = .{
            .max_clients = max_clients,
            .max_channels = 16,
            .max_subscribers_per_channel = 16,
        },
        .base_allocator = allocator,
        .address = undefined,
        .listener = null,
        .tls_listener = null,
        .tls = null,
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
        .stats = ServerStats.init(allocator, testing.io),
        .slowlog = slowlog,
        .latency = .{},
        .run_id = @splat('0'),
    };
    return server;
}

fn deinit_test_server(server: *Server) void {
    server.stats.deinit();
    server.slowlog.deinit();
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

    _ = try server.subscribe_to_channel("news", active.handle);
    _ = try server.subscribe_to_channel("news", .{ .slot_index = 1, .generation = 99 });

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

test "subscribe reports new subscriptions and unsubscribe removes them" {
    var server = try init_test_server(testing.allocator, 2);
    defer deinit_test_server(&server);

    const active = server.allocate_client_slot().?;
    active.slot.state.store(.active, .release);

    try testing.expect(try server.subscribe_to_channel("news", active.handle));
    // Duplicate subscriptions are ignored.
    try testing.expect(!try server.subscribe_to_channel("news", active.handle));
    try testing.expectEqual(@as(u32, 1), server.get_channel_count());

    try testing.expect(try server.unsubscribe_from_channel("news", active.handle));
    try testing.expect(!try server.unsubscribe_from_channel("news", active.handle));
    try testing.expectEqual(@as(u32, 0), server.get_channel_count());
}

test "subscribe_to_channel enforces channel and subscriber limits" {
    var server = try init_test_server(testing.allocator, 2);
    defer deinit_test_server(&server);

    server.config.max_channels = 1;
    server.config.max_subscribers_per_channel = 1;

    const first = server.allocate_client_slot().?;
    const second = server.allocate_client_slot().?;

    _ = try server.subscribe_to_channel("only", first.handle);
    try testing.expectError(error.ChannelLimitReached, server.subscribe_to_channel("other", first.handle));
    try testing.expectError(error.ChannelFull, server.subscribe_to_channel("only", second.handle));
    try testing.expectEqual(@as(u32, 1), server.get_channel_count());
}

test "unsubscribe_all returns every channel the client was on" {
    var server = try init_test_server(testing.allocator, 2);
    defer deinit_test_server(&server);

    const active = server.allocate_client_slot().?;
    active.slot.state.store(.active, .release);

    _ = try server.subscribe_to_channel("alpha", active.handle);
    _ = try server.subscribe_to_channel("beta", active.handle);

    const names = try server.unsubscribe_all(active.handle, testing.allocator);
    defer {
        for (names) |name| testing.allocator.free(name);
        testing.allocator.free(names);
    }

    try testing.expectEqual(@as(usize, 2), names.len);
    var saw_alpha = false;
    var saw_beta = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "alpha")) saw_alpha = true;
        if (std.mem.eql(u8, name, "beta")) saw_beta = true;
    }
    try testing.expect(saw_alpha and saw_beta);
    try testing.expectEqual(@as(u32, 0), server.get_channel_count());
}

/// Minimal server for memory-admission tests: store, KV allocator and registry
/// wired up as in `init_with_config`, but without a listener or AOF writer.
fn init_memory_test_server(allocator: Allocator, budget: usize, policy: Config.EvictionPolicy) !*Server {
    const server = try allocator.create(Server);
    errdefer allocator.destroy(server);

    server.* = .{
        .config = .{
            .kv_memory_budget = budget,
            .eviction_policy = policy,
            .max_clients = 1,
            .max_channels = 1,
            .max_subscribers_per_channel = 1,
        },
        .base_allocator = allocator,
        .address = undefined,
        .listener = null,
        .tls_listener = null,
        .tls = null,
        .io = testing.io,
        .client_slots = &.{},
        .free_list_head = .init(invalid_client_slot_index),
        .pubsub_map = .init(allocator),
        .kv_allocator = undefined,
        .clock = undefined,
        .store = undefined,
        .registry = undefined,
        .pubsub_context = undefined,
        .redisVersion = null,
        .createdTime = 0,
        .aof_writer = .{ .enabled = false },
        .stats = undefined,
        .slowlog = undefined,
        .latency = .{},
        .run_id = @splat('0'),
    };

    server.stats = ServerStats.init(allocator, testing.io);
    errdefer server.stats.deinit();
    server.slowlog = try SlowLog.init(allocator, 0);
    errdefer server.slowlog.deinit();
    server.kv_allocator = try KeyValueAllocator.init(allocator, budget, policy);
    server.clock = Clock.init(testing.io, 0);
    server.store = try Store.init(server.kv_allocator.allocator(), testing.io, &server.clock, .{
        .initial_capacity = 16,
        .eviction_policy = policy,
        .maxmemory_samples = 5,
    });
    server.kv_allocator.attach_store(&server.store);
    server.registry = try command_init.init_registry(allocator);
    server.pubsub_context = PubSubContext.init(server);
    return server;
}

fn deinit_memory_test_server(server: *Server) void {
    server.slowlog.deinit();
    server.stats.deinit();
    server.store.deinit();
    server.registry.deinit();
    server.pubsub_map.deinit();
    server.clock.deinit();
    server.base_allocator.destroy(server);
}

fn fill_past_budget(server: *Server, values: usize) !void {
    var value: [1024]u8 = undefined;
    @memset(&value, 'm');

    server.kv_allocator.begin_command();
    for (0..values) |i| {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "key-{d}", .{i});
        try server.store.set(key, value[0..]);
    }
    server.kv_allocator.end_command();
}

test "memory gate rejects denyoom commands when noeviction cannot meet the budget" {
    const server = try init_memory_test_server(testing.allocator, 4096, .noeviction);
    defer deinit_memory_test_server(server);

    try fill_past_budget(server, 8);
    try testing.expect(server.kv_allocator.get_memory_usage() > 4096);

    var client: Client = undefined;
    client.server = server;
    client.authenticated = true;

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const set_args = [_]Value{ .{ .data = "SET" }, .{ .data = "new" }, .{ .data = "value" } };
    try testing.expect(!server.memory_gate(&client, &set_args, &writer));
    try testing.expectEqualStrings("-OOM command not allowed when used memory > 'maxmemory'.\r\n", writer.buffered());

    // Reads and commands that free memory stay available, like Redis.
    writer = .fixed(&buffer);
    const get_args = [_]Value{ .{ .data = "GET" }, .{ .data = "key-0" } };
    try testing.expect(server.memory_gate(&client, &get_args, &writer));

    writer = .fixed(&buffer);
    const del_args = [_]Value{ .{ .data = "DEL" }, .{ .data = "key-0" } };
    try testing.expect(server.memory_gate(&client, &del_args, &writer));

    // Bad arity and unknown commands get their own error from the registry.
    writer = .fixed(&buffer);
    const bad_args = [_]Value{.{ .data = "SET" }};
    try testing.expect(server.memory_gate(&client, &bad_args, &writer));
}

test "memory gate evicts at the command boundary under allkeys-lru" {
    const server = try init_memory_test_server(testing.allocator, 4096, .allkeys_lru);
    defer deinit_memory_test_server(server);

    try fill_past_budget(server, 8);
    try testing.expect(server.kv_allocator.get_memory_usage() > 4096);

    var client: Client = undefined;
    client.server = server;
    client.authenticated = true;

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const set_args = [_]Value{ .{ .data = "SET" }, .{ .data = "new" }, .{ .data = "value" } };

    try testing.expect(server.memory_gate(&client, &set_args, &writer));
    try testing.expect(server.kv_allocator.get_memory_usage() <= 4096);
    try testing.expect(server.store.size() < 8);
}

fn initCommandTestClient(server: *Server) Client {
    var client: Client = undefined;
    client.connection = .none;
    client.allocator = server.base_allocator;
    client.authenticated = true;
    client.protocol_version = 2;
    client.name = null;
    client.lib_name = null;
    client.lib_ver = null;
    client.transaction = null;
    client.client_id = 1;
    client.command_registry = &server.registry;
    client.store = &server.store;
    client.server = server;
    return client;
}

test "EXEC runs queued commands and replies with each result" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const multi_args = [_]Value{.{ .data = "MULTI" }};
    server.execute_command(&client, &multi_args, &writer);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    try testing.expect(client.transaction != null);

    writer = std.Io.Writer.fixed(&buffer);
    const set_args = [_]Value{ .{ .data = "SET" }, .{ .data = "foo" }, .{ .data = "bar" } };
    server.execute_command(&client, &set_args, &writer);
    try testing.expectEqualStrings("+QUEUED\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    const get_args = [_]Value{ .{ .data = "GET" }, .{ .data = "foo" } };
    server.execute_command(&client, &get_args, &writer);
    try testing.expectEqualStrings("+QUEUED\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    const incr_args = [_]Value{ .{ .data = "INCR" }, .{ .data = "counter" } };
    server.execute_command(&client, &incr_args, &writer);
    try testing.expectEqualStrings("+QUEUED\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    const exec_args = [_]Value{.{ .data = "EXEC" }};
    server.execute_command(&client, &exec_args, &writer);

    try testing.expectEqualStrings("*3\r\n+OK\r\n$3\r\nbar\r\n:1\r\n", writer.buffered());
    try testing.expect(client.transaction == null);
}

test "EXEC aborts when a queued command could not be validated" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    server.execute_command(&client, &[_]Value{.{ .data = "MULTI" }}, &writer);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    server.execute_command(&client, &[_]Value{.{ .data = "NOTACOMMAND" }}, &writer);
    try testing.expectEqualStrings("-ERR unknown command 'NOTACOMMAND'\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    server.execute_command(&client, &[_]Value{.{ .data = "EXEC" }}, &writer);
    try testing.expectEqualStrings(
        "-EXECABORT Transaction discarded because of previous errors.\r\n",
        writer.buffered(),
    );
    try testing.expect(client.transaction == null);
}

test "DISCARD drops queued commands" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    server.execute_command(&client, &[_]Value{.{ .data = "MULTI" }}, &writer);
    server.execute_command(&client, &[_]Value{ .{ .data = "SET" }, .{ .data = "foo" }, .{ .data = "bar" } }, &writer);

    writer = std.Io.Writer.fixed(&buffer);
    server.execute_command(&client, &[_]Value{.{ .data = "DISCARD" }}, &writer);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    try testing.expect(client.transaction == null);
    try testing.expect(server.store.get("foo") == null);
}

test "transaction controls reject invalid states" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    server.execute_command(&client, &[_]Value{.{ .data = "EXEC" }}, &writer);
    try testing.expectEqualStrings("-ERR EXEC without MULTI\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    server.execute_command(&client, &[_]Value{.{ .data = "DISCARD" }}, &writer);
    try testing.expectEqualStrings("-ERR DISCARD without MULTI\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    server.execute_command(&client, &[_]Value{.{ .data = "MULTI" }}, &writer);
    try testing.expectEqualStrings("+OK\r\n", writer.buffered());

    writer = std.Io.Writer.fixed(&buffer);
    server.execute_command(&client, &[_]Value{.{ .data = "MULTI" }}, &writer);
    try testing.expectEqualStrings("-ERR MULTI calls can not be nested\r\n", writer.buffered());

    client.freeTransaction();
}

test "INFO returns server sections as a bulk string" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);
    try server.store.set("key", "value");

    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const server_commands = @import("../commands/server.zig");
    try server_commands.info_cmd(&client, &[_]Value{.{ .data = "INFO" }}, &writer);

    const output = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, output, "$"));
    try testing.expect(std.mem.indexOf(u8, output, "# Server\r\nredis_version:" ++ server_version) != null);
    try testing.expect(std.mem.indexOf(u8, output, "db0:keys=1,expires=0,avg_ttl=0") != null);
}

test "COMMAND COUNT matches the registry size" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);

    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const server_commands = @import("../commands/server.zig");
    try server_commands.command_cmd(&client, &[_]Value{ .{ .data = "COMMAND" }, .{ .data = "COUNT" } }, &writer);

    var expected: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&expected, ":{d}\r\n", .{server.registry.commands.count()});
    try testing.expectEqualStrings(text, writer.buffered());
}

test "COMMAND INFO describes a registered command" {
    const server = try init_memory_test_server(testing.allocator, 1024 * 1024, .noeviction);
    defer deinit_memory_test_server(server);
    defer resp.version = 2;

    var client = initCommandTestClient(server);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    const server_commands = @import("../commands/server.zig");
    try server_commands.command_cmd(
        &client,
        &[_]Value{ .{ .data = "COMMAND" }, .{ .data = "INFO" }, .{ .data = "GET" } },
        &writer,
    );

    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "*1\r\n*10\r\n$3\r\nGET\r\n:2\r\n"));
}
