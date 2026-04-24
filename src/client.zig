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

        // Create per-command arena for parsing (will be freed after enqueueing)
        // Use page_allocator directly as it's thread-safe (multiple clients parse concurrently)
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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

            // Enqueue command for store thread (single-threaded store access)
            // Dupe args into heap so they survive command.deinit()
            const cmd_args = try self.allocator.dupe(Value, command.getArgs());
            errdefer self.allocator.free(cmd_args);

            // Calculate total data size needed
            var total_data: usize = 0;
            for (cmd_args) |arg| {
                total_data += arg.data.len;
            }
            const arg_data = try self.allocator.alloc(u8, total_data);
            errdefer self.allocator.free(arg_data);

            // Copy data and fix up pointers
            var offset: usize = 0;
            for (cmd_args, 0..) |*arg, i| {
                const len = arg.data.len;
                @memcpy(arg_data[offset..][0..len], arg.data);
                arg.data = arg_data[offset..][0..len];
                offset += len;
                _ = i;
            }

            const cmd_node = try self.allocator.create(Server.CommandNode);
            errdefer self.allocator.destroy(cmd_node);
            cmd_node.* = .{
                .args = cmd_args,
                .arg_data = arg_data,
                .client = self,
                .done = .init(false),
            };
            log.debug("client {d}: enqueue cmd", .{self.client_id});
            self.server.command_queue.push(cmd_node);

            // Wait for store thread to process, flush mailbox while spinning
            var spin_count: usize = 0;
            while (!cmd_node.done.load(.acquire)) {
                self.flushMailbox() catch {};
                spin_count += 1;
                if (spin_count > 100) {
                    std.Thread.yield() catch {};
                    spin_count = 0;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            log.debug("client {d}: cmd done, flushing mailbox", .{self.client_id});

            self.allocator.free(cmd_node.args);
            self.allocator.free(cmd_node.arg_data);
            self.allocator.destroy(cmd_node);

            // Free command data AFTER store thread is done
            command.deinit();

            self.flushMailbox() catch return;

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
        defer freeMessageList(self.allocator, head);

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
