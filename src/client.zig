const std = @import("std");
const Connection = std.net.Server.Connection;
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
    connection: Connection,
    current_db: u8,
    databases: *[16]Store,
    is_in_pubsub_mode: bool,
    pubsub_context: *PubSubContext,
    server: *Server,
    writer: std.net.Stream.Writer,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: Connection,
        pubsub_context: *PubSubContext,
        registry: *CommandRegistry,
        server: *Server,
        databases: *[16]Store,
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
            .writer = connection.stream.writer(&.{}),
        };
    }

    pub fn deinit(self: *Client) void {
        self.connection.stream.close();
    }

    pub fn enterPubSubMode(self: *Client) void {
        self.is_in_pubsub_mode = true;
        std.log.debug("Client {} entered pubsub mode", .{self.client_id});
    }

    pub fn handle(self: *Client) !void {
        var reader_buffer: [1024 * 16]u8 = undefined;
        var sr = self.connection.stream.reader(&reader_buffer);
        const reader = sr.interface();
        var writer_buffer: [1024 * 16]u8 = undefined;
        var sw = self.connection.stream.writer(&writer_buffer);
        const writer = &sw.interface;

        // Create per-thread arena for temporary allocations
        // This eliminates per-command malloc/free overhead
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        while (true) {
            // Use arena allocator for all temporary command processing
            // All allocations will be bulk-freed by arena.reset()
            const arena_allocator = arena.allocator();

            // Parse the incoming command from the client's stream.
            var parser = Parser.init(arena_allocator);

            var command = parser.parse(reader) catch |err| {
                // If there's an error (like a closed connection), we stop handling this client.
                if (err == error.EndOfStream) {
                    // In pubsub mode, we might want to keep the connection open even on EndOfStream
                    if (self.is_in_pubsub_mode) {
                        std.log.debug("Client {} in pubsub mode, connection ended", .{self.client_id});
                    }
                    return;
                }
                // Socket error, the connection should be closed.
                if (err == error.ReadFailed) {
                    if (self.is_in_pubsub_mode) {
                        std.log.debug("Client {} in pubsub mode, read failed", .{self.client_id});
                    }
                    return;
                }
                std.log.err("Parse error: {s}", .{@errorName(err)});
                resp.writeError(writer, "ERR protocol error") catch {};

                // Reset arena to free any partially allocated memory from failed parse
                _ = arena.reset(.retain_capacity);
                continue;
            };
            defer command.deinit();

            // Execute the parsed command.
            try self.executeCommand(writer, command);

            // Reset arena to bulk-free all temporary allocations from this command
            // This is much faster than individual free() calls
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
