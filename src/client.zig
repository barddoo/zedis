const std = @import("std");
const Stream = std.Io.net.Stream;
const posix = std.posix;
const pollfd = posix.pollfd;
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
const PubSubContext = @import("./commands/pubsub.zig").PubSubContext;
const ClientMailbox = @import("./client_mailbox.zig").ClientMailbox;
const freeMessageList = @import("./client_mailbox.zig").freeMessageList;
const Config = @import("./config.zig");
const resp = @import("./commands/resp.zig");
const ClientHandle = @import("./types.zig").ClientHandle;
const StackWriter = @import("stack_writer.zig").StackWriter;

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

    pub fn enterPubSubMode(self: *Client) void {
        self.is_in_pubsub_mode = true;
        log.debug("Client {} entered pubsub mode", .{self.client_id});
    }

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

            try self.flushMailbox();
            if (self.disconnect_requested.load(.acquire)) return;

            // Use arena allocator for parsing (temporary)
            const arena_allocator = arena.allocator();

            // Parse the incoming command from the client's stream
            // Io.Reader blocks natively — no need for poll()
            var parser = Parser.init(arena_allocator);

            var command = parser.parse(reader) catch |err| {
                // If there's an error (like a closed connection), we stop handling this client
                if (err == error.EndOfStream) {
                    if (self.is_in_pubsub_mode) {
                        log.debug("Client {} in pubsub mode, connection ended", .{self.client_id});
                    }
                    return;
                }
                // Socket error, the connection should be closed
                if (err == error.ReadFailed) {
                    if (self.is_in_pubsub_mode) {
                        log.debug("Client {} in pubsub mode, read failed", .{self.client_id});
                    }
                    return;
                }
                log.err("Parse error: {s} client_id={d}", .{ @errorName(err), self.client_id });

                // Send error response directly (parse errors happen before enqueueing)
                var writer_buffer: [1024]u8 = undefined;
                var sw = self.connection.writer(self.io, &writer_buffer);
                sw.interface.writeAll("-ERR protocol error\r\n") catch {};
                sw.interface.flush() catch {};

                // Reset arena to free any partially allocated memory from failed parse
                _ = arena.reset(.retain_capacity);
                continue;
            };

            // Execute command directly in client thread (store_mutex serializes access)
            while (!self.server.store_mutex.tryLock()) {
                std.atomic.spinLoopHint();
            }
            var sw = StackWriter.init(self.allocator);
            var response_writer = sw.writer();
            self.server.processCommandDirect(self, command.getArgs(), &response_writer);
            self.server.store_mutex.unlock();

            command.deinit();

            // Write response directly to socket (no mailbox indirection)
            const response = sw.slice(&response_writer);
            if (response.len > 0) {
                var writer_buffer: [1024 * 4]u8 = undefined;
                var socket_writer = self.connection.writer(self.io, &writer_buffer);
                try socket_writer.interface.writeAll(response);
                try socket_writer.interface.flush();
            }
            sw.deinit();

            // Check mailbox for pubsub messages that arrived during command execution
            try self.flushMailbox();

            if (self.disconnect_requested.load(.acquire)) {
                log.debug("client {d}: disconnect after cmd", .{self.client_id});
                return;
            }

            // Reset arena to free parsing allocations
            _ = arena.reset(.retain_capacity);

            // If we're in pubsub mode after executing a command, stay connected
            if (self.is_in_pubsub_mode) {
                log.debug("Client {} staying in pubsub mode", .{self.client_id});
            }
        }
    }

    // Dispatches the parsed command to the appropriate handler function.
    fn executeCommand(self: *Client, writer: *std.Io.Writer, command: Command) !void {
        try self.command_registry.executeCommandClient(self, writer, command.getArgs());
    }

    pub fn isAuthenticated(self: *Client) bool {
        return self.authenticated or !self.server.config.requiresAuth();
    }

    // Helper to get the store
    pub fn getCurrentStore(self: *Client) *Store {
        return self.store;
    }

    fn waitForReadable(self: *Client, timeout_ms: i32) !bool {
        var fds = [_]pollfd{.{
            .fd = self.connection.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try posix.poll(&fds, timeout_ms);
        if (ready == 0) return false;

        const revents = fds[0].revents;
        if (revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            return error.EndOfStream;
        }

        return revents & std.posix.POLL.IN != 0;
    }

    fn flushMailbox(self: *Client) !void {
        const head = self.mailbox.takeAll();
        defer self.mailbox.freeNodes(self.allocator, head);

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
