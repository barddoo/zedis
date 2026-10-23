const std = @import("std");
const zio = @import("zio");
const Stream = std.Io.net.Stream;
const Allocator = std.mem.Allocator;
const Parser = @import("../protocol/parser.zig");
const store_mod = @import("../storage/store.zig");
const Store = store_mod.Store;
const ZedisObject = store_mod.ZedisObject;
const ZedisValue = store_mod.ZedisValue;
const ZedisList = store_mod.ZedisList;
const PrimitiveValue = store_mod.PrimitiveValue;
const Command = @import("../protocol/parser.zig").Command;
const Value = @import("../protocol/parser.zig").Value;
const CommandRegistry = @import("../commands/registry.zig").CommandRegistry;
const Server = @import("server.zig");
const StackWriter = @import("../util/stack_writer.zig").StackWriter;
const PubSubContext = @import("../commands/pubsub.zig").PubSubContext;
const ClientMailbox = @import("../util/client_mailbox.zig").ClientMailbox;
const free_message_list = @import("../util/client_mailbox.zig").free_message_list;
const Config = @import("config.zig");
const resp = @import("../protocol/resp.zig");
const ClientHandle = @import("../util/types.zig").ClientHandle;

const log = std.log.scoped(.client);

/// Flush a reply batch once it grows past this many bytes, bounding
/// per-connection memory for very long pipelines or large replies.
const max_batch_bytes = 64 * 1024;

/// Parse arena memory kept across commands; anything above is released after
/// a command with large arguments.
const parse_arena_retain_bytes = 64 * 1024;

var next_client_id: std.atomic.Value(u64) = .init(1);

pub const Client = struct {
    allocator: std.mem.Allocator,
    authenticated: bool,
    client_id: u64,
    slot_handle: ClientHandle,
    command_registry: *CommandRegistry,
    connection: Stream,
    store: *Store,
    is_in_pubsub_mode: bool,
    pubsub_context: *PubSubContext,
    mailbox: *ClientMailbox,
    /// Signaled when a pub/sub message is enqueued; wakes the delivery task.
    mailbox_event: *zio.Event,
    disconnect_requested: *std.atomic.Value(bool),
    server: *Server,
    io: std.Io,
    /// AOF offset just past this client's last logged command; replies wait for
    /// it to be durable under appendfsync always.
    aof_end: u64 = 0,
    /// Task that pushes pub/sub messages while the client is idle (its main
    /// coroutine blocks reading the socket). Started on first SUBSCRIBE.
    delivery_group: std.Io.Group = .init,
    delivery_started: bool = false,
    /// Serializes socket writes between the client coroutine and the delivery
    /// task. Unlike the store, writes may suspend, so this is a parking mutex.
    write_mutex: zio.Mutex = .init,
    /// Channels this client is subscribed to, for the SUBSCRIBE reply count.
    subscription_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: Stream,
        pubsub_context: *PubSubContext,
        registry: *CommandRegistry,
        server: *Server,
        store: *Store,
        slot_handle: ClientHandle,
        mailbox: *ClientMailbox,
        mailbox_event: *zio.Event,
        disconnect_requested: *std.atomic.Value(bool),
        io: std.Io,
    ) Client {
        const id = next_client_id.fetchAdd(1, .monotonic);

        return .{
            .allocator = allocator,
            .authenticated = false,
            .client_id = id,
            .slot_handle = slot_handle,
            .command_registry = registry,
            .connection = connection,
            .store = store,
            .is_in_pubsub_mode = false,
            .pubsub_context = pubsub_context,
            .mailbox = mailbox,
            .mailbox_event = mailbox_event,
            .disconnect_requested = disconnect_requested,
            .server = server,
            .io = io,
        };
    }

    pub fn deinit(self: *Client) void {
        self.stop_mailbox_delivery();
        self.connection.close(self.io);
    }

    /// Starts the coroutine that pushes pub/sub messages to this socket. Safe
    /// to call repeatedly; SUBSCRIBE calls it on every subscription.
    pub fn start_mailbox_delivery(self: *Client) void {
        if (self.delivery_started) return;
        self.mailbox_event.reset();
        self.delivery_started = true;
        self.delivery_group.async(self.io, delivery_task, .{self});
    }

    fn delivery_task(self: *Client) void {
        self.delivery_loop() catch {};
    }

    fn stop_mailbox_delivery(self: *Client) void {
        if (!self.delivery_started) return;
        self.delivery_group.cancel(self.io);
        self.delivery_started = false;
    }

    /// Waits for a message, then drains the mailbox. The mailbox lock makes the
    /// reset race-free against `enqueue_to_handle`, which appends and signals
    /// under the same lock.
    fn delivery_loop(self: *Client) !void {
        while (true) {
            try self.mailbox_event.wait();
            try self.drain_mailbox();
            if (self.disconnect_requested.load(.acquire)) return;
        }
    }

    fn drain_mailbox(self: *Client) !void {
        while (true) {
            try self.flush_mailbox();

            self.mailbox.lock_atomic();
            const empty = self.mailbox.pending_count == 0;
            if (empty) self.mailbox_event.reset();
            self.mailbox.unlock_atomic();
            if (empty) return;
        }
    }

    pub fn enter_pub_sub_mode(self: *Client) void {
        self.is_in_pubsub_mode = true;
        log.debug("Client {} entered pubsub mode", .{self.client_id});
    }

    /// Errors the client's command reader can raise: whatever the socket
    /// reader and RESP parser surface, plus `error.Timeout` from the
    /// idle-client deadline enforced with zio.withTimeout.
    const CommandReadError = error{
        InvalidProtocol,
        EndOfStream,
        StreamTooLong,
        ReadFailed,
        OutOfMemory,
        Canceled,
        Timeout,
    };

    pub fn handle(self: *Client) !void {
        var reader_buffer: [1024 * 16]u8 = undefined;
        var sr = self.connection.reader(self.io, &reader_buffer);
        const reader = &sr.interface;

        // Per-command arena for args that don't fit in the reader buffer (and
        // for >6-arg lists). Commands that are fully buffered borrow their args
        // from the reader buffer and never touch it.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        while (true) {
            if (self.disconnect_requested.load(.acquire)) return;

            try self.flush_mailbox();
            if (self.disconnect_requested.load(.acquire)) return;

            const arena_allocator = arena.allocator();

            // Accumulate the replies of every command already buffered from the
            // socket, then flush them with a single write. Without this, each
            // pipelined command costs its own write syscall and event-loop
            // round trip.
            var sw = StackWriter.init(self.server.base_allocator);
            defer sw.deinit();
            const response_writer = sw.writer();

            // Only the first command of a batch may wait for the socket; the rest
            // must already be buffered, so the batch never blocks with replies
            // pending.
            var may_block = true;
            batch: while (true) {
                var parser = Parser.init(arena_allocator);

                const maybe_command = self.next_command(&parser, reader, may_block) catch |err| {
                    switch (err) {
                        error.Timeout => {
                            log.debug("Client {d} idle timeout", .{self.client_id});
                            self.write_batch(sw.slice(response_writer)) catch {};
                            return;
                        },
                        error.EndOfStream, error.ReadFailed, error.Canceled => {
                            self.write_batch(sw.slice(response_writer)) catch {};
                            return;
                        },
                        else => {
                            log.err("Protocol error: {s} client_id={d}", .{ @errorName(err), self.client_id });
                            // Protocol errors are fatal: the stream is
                            // desynchronized, so continuing would re-parse the
                            // same bad bytes forever. Reply then close, like Redis.
                            response_writer.writeAll("-ERR protocol error\r\n") catch {};
                            self.write_batch(sw.slice(response_writer)) catch {};
                            return;
                        },
                    }
                };
                const command = maybe_command orelse break :batch;
                may_block = false;

                // Execute the command inline on this coroutine. The single zio
                // executor serializes it against other clients; there is no store
                // thread and no store lock.
                self.server.execute_command(self, command.get_args(), response_writer);
                _ = arena.reset(.{ .retain_with_limit = parse_arena_retain_bytes });

                // Bound the reply batch; next_command ends it once no complete
                // command is buffered.
                if (sw.slice(response_writer).len >= max_batch_bytes) break :batch;
            }

            self.write_batch(sw.slice(response_writer)) catch return;

            if (self.disconnect_requested.load(.acquire)) {
                log.debug("client {d}: disconnect after cmd", .{self.client_id});
                return;
            }

            // Check mailbox for pubsub messages that arrived during command execution
            try self.flush_mailbox();

            if (self.disconnect_requested.load(.acquire)) {
                log.debug("client {d}: disconnect after flush", .{self.client_id});
                return;
            }

            if (self.is_in_pubsub_mode) {
                log.debug("Client {} staying in pubsub mode", .{self.client_id});
            }
        }
    }

    /// Write accumulated reply bytes to the socket and flush.
    fn write_batch(self: *Client, response: []const u8) !void {
        if (response.len == 0) return;

        // appendfsync always: don't acknowledge writes before they are fsynced.
        // Command execution is finished here, so other clients keep running.
        if (!self.server.aof_writer.wait_durable(self.aof_end)) {
            // The AOF failed before these writes were durable. Send the MISCONF
            // error instead of the replies and close the connection.
            var error_buffer: [256]u8 = undefined;
            var error_writer: std.Io.Writer = .fixed(&error_buffer);
            if (self.server.aof_writer.failure()) |failure| failure.write_error(&error_writer) catch {};
            try self.write_socket(error_writer.buffered());
            return error.AofFailed;
        }
        try self.write_socket(response);
    }

    fn write_socket(self: *Client, bytes: []const u8) !void {
        if (bytes.len == 0) return;

        self.write_mutex.lockUncancelable();
        defer self.write_mutex.unlock();

        var writer_buffer: [1024 * 4]u8 = undefined;
        var socket_writer = self.connection.writer(self.io, &writer_buffer);
        // The peer may have gone away while the command ran; a failed write
        // just ends this connection.
        try socket_writer.interface.writeAll(bytes);
        try socket_writer.interface.flush();
    }

    /// Next command for this batch. A command that is already fully buffered is
    /// parsed zero-copy in one pass: its args slice the reader buffer and stay
    /// valid until the next read, which only happens after execution. Otherwise,
    /// with `may_block`, waits for it on the socket (copying parse); without it,
    /// returns null so the batch can be flushed.
    fn next_command(self: *Client, parser: *Parser, reader: *std.Io.Reader, may_block: bool) CommandReadError!?Command {
        if (try parser.parse_buffered(std.Io.Reader.buffered(reader))) |parsed| {
            reader.toss(parsed.consumed);
            return parsed.command;
        }
        if (!may_block) return null;
        return try self.read_command(parser, reader);
    }

    /// Parse one command, enforcing the configured idle `timeout` (in seconds)
    /// on how long the client may take to deliver it. 0 disables the deadline.
    fn read_command(self: *Client, parser: *Parser, reader: *std.Io.Reader) CommandReadError!Command {
        const idle_timeout = self.server.config.timeout;
        if (idle_timeout == 0) return parse_command(parser, reader);
        return zio.withTimeout(.fromSeconds(idle_timeout), parse_command, .{ parser, reader });
    }

    fn parse_command(parser: *Parser, reader: *std.Io.Reader) CommandReadError!Command {
        return parser.parse(reader);
    }

    pub fn is_authenticated(self: *Client) bool {
        return self.authenticated or !self.server.config.requires_auth();
    }

    // Helper to get the store
    pub fn get_current_store(self: *Client) *Store {
        return self.store;
    }

    fn flush_mailbox(self: *Client) !void {
        const head = self.mailbox.take_all();
        defer self.mailbox.free_nodes(self.allocator, head);

        if (head == null) return;

        self.write_mutex.lockUncancelable();
        defer self.write_mutex.unlock();

        var writer_buffer: [1024 * 4]u8 = undefined;
        var sw = self.connection.writer(self.io, &writer_buffer);
        const writer = &sw.interface;

        var current = head;
        while (current) |node| : (current = node.next) {
            try writer.writeAll(node.bytes);
        }

        try writer.flush();
    }
};
