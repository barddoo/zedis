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
const Server = @import("./server.zig").Server;
const PubSubContext = @import("./pubsub/pubsub.zig").PubSubContext;
const ServerConfig = @import("./server_config.zig").ServerConfig;
const resp = @import("./commands/resp.zig");

var next_client_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

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
        var sr = self.connection.stream.reader(&.{});
        const reader = sr.interface();
        var sw = self.connection.stream.writer(&.{});
        const writer = &sw.interface;

        while (true) {
            // Parse the incoming command from the client's stream.
            var parser = Parser.init(self.allocator);
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
                continue;
            };
            defer command.deinit();

            // Execute the parsed command.
            try self.executeCommand(command);

            // If we're in pubsub mode after executing a command, stay connected
            if (self.is_in_pubsub_mode) {
                std.log.debug("Client {} staying in pubsub mode", .{self.client_id});
            }
        }
    }

    // Dispatches the parsed command to the appropriate handler function.
    fn executeCommand(self: *Client, command: Command) !void {
        try self.command_registry.executeCommandClient(self, command.args.items);
    }

    pub fn isAuthenticated(self: *Client) bool {
        return self.authenticated or !self.server.config.requiresAuth();
    }

    // Helper to get the currently selected database
    pub fn getCurrentStore(self: *Client) *Store {
        return &self.databases[self.current_db];
    }
};
