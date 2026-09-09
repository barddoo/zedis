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
const CommandNode = Server.CommandNode;
const PubSubContext = @import("./commands/pubsub.zig").PubSubContext;
const ClientMailbox = @import("./client_mailbox.zig").ClientMailbox;
const free_message_list = @import("./client_mailbox.zig").free_message_list;
const Config = @import("./config.zig");
const resp = @import("./commands/resp.zig");
const ClientHandle = @import("./types.zig").ClientHandle;

const log = std.log.scoped(.client);

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
    disconnect_requested: *std.atomic.Value(bool),
    server: *Server,
    io: std.Io,
    parse_buffer: [65536]u8 = undefined,

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

        // Per-command arena for parsing.
        // Uses a fixed buffer in the Client struct to avoid page_allocator syscalls.
        var fba = std.heap.FixedBufferAllocator.init(self.parse_buffer[0..]);
        var arena = std.heap.ArenaAllocator.init(fba.allocator());
        defer arena.deinit();

        while (true) {
            if (self.disconnect_requested.load(.acquire)) return;

            try self.flush_mailbox();
            if (self.disconnect_requested.load(.acquire)) return;

            // Use arena allocator for parsing (temporary)
            const arena_allocator = arena.allocator();

            var parser = Parser.init(arena_allocator);

            const command = self.read_command(&parser, reader) catch |err| {
                switch (err) {
                    error.Timeout => {
                        log.debug("Client {d} idle timeout", .{self.client_id});
                        return;
                    },
                    error.EndOfStream, error.ReadFailed, error.Canceled => return,
                    else => {
                        // Parse errors happen before enqueueing; respond directly.
                        log.err("Parse error: {s} client_id={d}", .{ @errorName(err), self.client_id });

                        var writer_buffer: [1024]u8 = undefined;
                        var sw = self.connection.writer(self.io, &writer_buffer);
                        sw.interface.writeAll("-ERR protocol error\r\n") catch {};
                        sw.interface.flush() catch {};

                        // Reset arena to free any partially allocated memory from failed parse
                        _ = arena.reset(.retain_capacity);
                        continue;
                    },
                }
            };

            // Hand the command to the dedicated store thread and wait until it
            // has executed it and built the response.
            const node = try self.enqueue_command(arena_allocator, command);

            if (node.response) |response| {
                node.response = null;
                defer self.server.base_allocator.free(response);

                if (response.len > 0) {
                    var writer_buffer: [1024 * 4]u8 = undefined;
                    var socket_writer = self.connection.writer(self.io, &writer_buffer);
                    // The peer may have gone away while the command ran; a
                    // failed write just ends this connection.
                    socket_writer.interface.writeAll(response) catch return;
                    socket_writer.interface.flush() catch return;
                }
            }

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

            // Reset arena to free parsing allocations. Safe now: the store
            // thread only touched node/args until it set node.done, which is
            // what woke us above.
            _ = arena.reset(.retain_capacity);

            if (self.is_in_pubsub_mode) {
                log.debug("Client {} staying in pubsub mode", .{self.client_id});
            }
        }
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

    /// Queue `command` for execution on the store thread and wait for it to be
    /// processed. The returned node carries the response. node.args reference
    /// the caller's arena/stack memory and must stay valid until the store
    /// thread sets node.done (which is when this function returns).
    fn enqueue_command(self: *Client, arena_allocator: Allocator, command: Command) !*CommandNode {
        const node = try arena_allocator.create(CommandNode);
        node.* = .{
            .args = command.get_args(),
            .client = self,
        };
        self.server.submit_to_store(node);
        try node.done.wait(self.io);
        return node;
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
