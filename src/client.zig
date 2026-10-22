const std = @import("std");
const zio = @import("zio");
const Stream = std.Io.net.Stream;
const Allocator = std.mem.Allocator;
const Parser = @import("parser.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const ZedisObject = store_mod.ZedisObject;
const ZedisValue = store_mod.ZedisValue;
const ZedisList = store_mod.ZedisList;
const PrimitiveValue = store_mod.PrimitiveValue;
const Command = @import("parser.zig").Command;
const Value = @import("parser.zig").Value;
const CommandRegistry = @import("./commands/registry.zig").CommandRegistry;
const Server = @import("./server.zig");
const StackWriter = @import("stack_writer.zig").StackWriter;
const PubSubContext = @import("./commands/pubsub.zig").PubSubContext;
const ClientMailbox = @import("./client_mailbox.zig").ClientMailbox;
const free_message_list = @import("./client_mailbox.zig").free_message_list;
const Config = @import("./config.zig");
const resp = @import("./commands/resp.zig");
const ClientHandle = @import("./types.zig").ClientHandle;

const log = std.log.scoped(.client);

/// Flush a reply batch once it grows past this many bytes, bounding
/// per-connection memory for very long pipelines or large replies.
const max_batch_bytes = 64 * 1024;

/// Parse arena memory kept across commands; anything above is released after
/// a command with large arguments.
const parse_arena_retain_bytes = 64 * 1024;

var next_client_id: std.atomic.Value(u64) = .init(1);

/// Returns true if `buffered` begins with at least one complete RESP command.
///
/// The parser consumes exactly one command and leaves the rest in the reader,
/// so this lets the client keep executing pipelined commands that are already
/// buffered without re-entering the event loop (and flushing) between them.
/// It only decides "can I parse again without blocking"; malformed input is
/// left for the parser to report.
fn has_complete_command(buffered: []const u8) bool {
    if (buffered.len == 0) return false;

    // Inline command: complete once its line terminator is buffered.
    if (buffered[0] != '*') {
        return std.mem.indexOfScalar(u8, buffered, '\n') != null;
    }

    // RESP array: *<count>\r\n followed by <count> bulk strings.
    const header_end = std.mem.indexOfScalar(u8, buffered, '\n') orelse return false;
    const count_text = std.mem.trimEnd(u8, buffered[1..header_end], "\r");
    const count = std.fmt.parseInt(usize, count_text, 10) catch return true;

    var pos = header_end + 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const bulk_header_end = std.mem.indexOfScalarPos(u8, buffered, pos, '\n') orelse return false;
        const bulk_header = buffered[pos..bulk_header_end];
        if (bulk_header.len == 0 or bulk_header[0] != '$') return true;

        const len_text = std.mem.trimEnd(u8, bulk_header[1..], "\r");
        const len = std.fmt.parseInt(usize, len_text, 10) catch return true;

        const data_start = bulk_header_end + 1;
        const data_end = std.math.add(usize, data_start, len) catch return true;
        if (data_end > buffered.len) return false;
        if (data_end + 2 > buffered.len) return false;
        if (buffered[data_end] != '\r' or buffered[data_end + 1] != '\n') return true;

        pos = data_end + 2;
    }

    return true;
}

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
    disconnect_requested: *std.atomic.Value(bool),
    server: *Server,
    io: std.Io,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: Stream,
        pubsub_context: *PubSubContext,
        registry: *CommandRegistry,
        server: *Server,
        store: *Store,
        slot_handle: ClientHandle,
        mailbox: *ClientMailbox,
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
            .disconnect_requested = disconnect_requested,
            .server = server,
            .io = io,
        };
    }

    pub fn deinit(self: *Client) void {
        self.connection.close(self.io);
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

            batch: while (true) {
                var parser = Parser.init(arena_allocator);

                const command = self.read_command(&parser, reader) catch |err| {
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

                // Execute the command inline on this coroutine. The store lock
                // serializes it against other clients; there is no store thread.
                self.server.execute_command(self, command.get_args(), response_writer);
                _ = arena.reset(.{ .retain_with_limit = parse_arena_retain_bytes });

                // Keep batching only while another complete command is already
                // buffered (so parsing it won't block) and the reply is bounded.
                const buffered = std.Io.Reader.buffered(reader);
                if (buffered.len == 0) break :batch;
                if (sw.slice(response_writer).len >= max_batch_bytes) break :batch;
                if (!has_complete_command(buffered)) break :batch;
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

        var writer_buffer: [1024 * 4]u8 = undefined;
        var socket_writer = self.connection.writer(self.io, &writer_buffer);
        // The peer may have gone away while the command ran; a failed write
        // just ends this connection.
        try socket_writer.interface.writeAll(response);
        try socket_writer.interface.flush();
    }

    /// Parse one command, enforcing the configured idle `timeout` (in seconds)
    /// on how long the client may take to deliver it. 0 disables the deadline.
    fn read_command(self: *Client, parser: *Parser, reader: *std.Io.Reader) CommandReadError!Command {
        // Zero-copy fast path: the whole command is buffered, so parse it from
        // a non-refilling view and hand out slices of the reader buffer. They
        // stay valid until the next read, which happens only after execution.
        const buffered = std.Io.Reader.buffered(reader);
        if (has_complete_command(buffered)) {
            var view: std.Io.Reader = .fixed(buffered);
            const command = parser.parse_borrowed(&view) catch |err| switch (err) {
                // has_complete_command saw the full command, so running out of
                // bytes means the framing is inconsistent.
                error.EndOfStream => return error.InvalidProtocol,
                else => |e| return e,
            };
            reader.toss(view.seek);
            return command;
        }

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
