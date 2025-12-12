const std = @import("std");
const Stream = std.Io.net.Stream;
const posix = std.posix;
const pollfd = posix.pollfd;
const Parser = @import("parser.zig").Parser;
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const ZedisObject = store_mod.ZedisObject;
const ZedisValue = store_mod.ZedisValue;
const ZedisList = store_mod.ZedisList;
const PrimitiveValue = store_mod.PrimitiveValue;
const Command = @import("parser.zig").Command;
const CommandRegistry = @import("./commands/registry.zig").CommandRegistry;
const Server = @import("./server.zig");
const PubSubContext = @import("./commands/pubsub.zig").PubSubContext;
const Config = @import("./config.zig").Config;
const resp = @import("./commands/resp.zig");

var next_client_id: std.atomic.Value(u64) = .init(1);

pub const Client = struct {
    allocator: std.mem.Allocator,
    authenticated: bool,
    client_id: u64,
    command_registry: *CommandRegistry,
    connection: Stream,
    current_db: u8,
    databases: *[16]Store,
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
        databases: *[16]Store,
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
            .databases = databases,
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
        var reader_buffer: [1024 * 16]u8 = undefined;
        var sr = self.connection.reader(self.io, &reader_buffer);
        const reader = &sr.interface;

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
                var writer_buffer: [1024]u8 = undefined;
                var sw = self.connection.writer(self.io, &writer_buffer);
                sw.interface.writeAll("-ERR protocol error\r\n") catch {};
                sw.interface.flush() catch {};

                // Reset arena to free any partially allocated memory from failed parse
                _ = arena.reset(.retain_capacity);
                continue;
            };
            defer command.deinit();

            // Execute command directly (one thread per connection)
            var writer_buffer: [1024 * 16]u8 = undefined;
            var sw = self.connection.writer(self.io, &writer_buffer);
            const writer = &sw.interface;

            try self.command_registry.executeCommandClient(self, writer, command.getArgs());

            // Reset arena to free parsing allocations
            _ = arena.reset(.retain_capacity);

            // If we're in pubsub mode after executing a command, stay connected
            if (self.is_in_pubsub_mode) {
                std.log.debug("Client {} staying in pubsub mode", .{self.client_id});
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

    // Helper to get the currently selected database
    pub fn getCurrentStore(self: *Client) *Store {
        return &self.databases[self.current_db];
    }
};
