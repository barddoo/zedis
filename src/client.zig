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

var next_client_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub const Client = struct {
    allocator: std.mem.Allocator,
    authenticated: bool,
    client_id: u64,
    command_registry: *CommandRegistry,
    connection: Connection,
    is_in_pubsub_mode: bool,
    pubsub_context: *PubSubContext,
    server: *Server,
    store: *Store,
    writer: std.net.Stream.Writer,

    pub fn init(
        allocator: std.mem.Allocator,
        connection: Connection,
        pubsub_context: *PubSubContext,
        registry: *CommandRegistry,
        server: *Server,
        store: *Store,
    ) Client {
        const id = next_client_id.fetchAdd(1, .monotonic);
        return .{
            .allocator = allocator,
            .authenticated = false,
            .client_id = id,
            .command_registry = registry,
            .connection = connection,
            .is_in_pubsub_mode = false,
            .pubsub_context = pubsub_context,
            .server = server,
            .store = store,
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
        while (true) {
            // Parse the incoming command from the client's stream.
            var parser = Parser.init(self.allocator, self.connection.stream);
            var command = parser.parse() catch |err| {
                // If there's an error (like a closed connection), we stop handling this client.
                if (err == error.EndOfStream) {
                    // In pubsub mode, we might want to keep the connection open even on EndOfStream
                    if (self.is_in_pubsub_mode) {
                        std.log.debug("Client {} in pubsub mode, connection ended", .{self.client_id});
                    }
                    return;
                }
                if (err == error.ReadFailed) {
                    if (self.is_in_pubsub_mode) {
                        std.log.debug("Client {} in pubsub mode, read failed", .{self.client_id});
                    }
                    return err;
                }
                std.log.err("Parse error: {s}", .{@errorName(err)});
                self.writeError("ERR protocol error", .{}) catch {};
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
        try self.command_registry.executeCommand(self, command.args.items);
    }

    pub fn isAuthenticated(self: *Client) bool {
        return !self.server.config.requiresAuth() or self.authenticated;
    }

    // --- RESP Writing Helpers ---

    pub fn writeError(self: *Client, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        const formatted = try std.fmt.allocPrint(self.allocator, "-{s}\r\n", .{msg});
        defer self.allocator.free(formatted);
        _ = try self.writer.interface.write(formatted);
    }

    pub fn writeBulkString(self: *Client, str: []const u8) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, "${d}\r\n{s}\r\n", .{ str.len, str });
        defer self.allocator.free(formatted);
        _ = try self.writer.interface.write(formatted);
    }

    pub fn writeIntAsString(self: *Client, i: i64) !void {
        var buf: [20]u8 = undefined;
        const int_str = try std.fmt.bufPrint(&buf, "{d}", .{i});
        try self.writeBulkString(int_str);
    }

    pub fn writeInt(self: *Client, value: anytype) !void {
        const T = @TypeOf(value);
        comptime {
            if (T != i64 and T != usize and T != comptime_int) {
                @compileError("writeInt only accepts i64, usize, or comptime_int");
            }
        }
        _ = try self.writer.interface.print(":{d}\r\n", .{value});
    }

    pub fn writeListLen(self: *Client, count: usize) !void {
        try self.writer.interface.print("*{d}\r\n", .{count});
    }

    pub fn writeTupleAsArray(self: *Client, items: anytype) !void {
        const T = @TypeOf(items);
        const info = @typeInfo(T);

        // 2. At compile time, verify the input is a tuple.
        //    A tuple in Zig is an anonymous struct.
        comptime {
            switch (info) {
                .@"struct" => |struct_info| {
                    if (!struct_info.is_tuple) {
                        @compileError("This function only accepts a tuple. Received: " ++ @typeName(T));
                    }
                },
                else => @compileError("This function only accepts a tuple. Received: " ++ @typeName(T)),
            }
        }

        const struct_info = info.@"struct";

        const formatted = try std.fmt.allocPrint(self.allocator, "*{d}\r\n", .{struct_info.fields.len});
        _ = try self.writer.interface.write(formatted);

        // 4. Use 'inline for' to iterate over the tuple's elements at compile time.
        //    This loop is "unrolled" by the compiler, generating specific code
        //    for each element's type with no runtime overhead.
        inline for (items) |item| {
            // Check the type of the current item and call the correct serializer.
            const ItemType = @TypeOf(item);
            if (ItemType == []const u8) {
                try self.writeBulkString(item);
            } else if (ItemType == i64) {
                try self.writeInt(item);
            } else {
                // Handle string literals and other pointer-to-array types by checking if they can be coerced to []const u8
                const item_as_slice: []const u8 = item;
                try self.writeBulkString(item_as_slice);
            }
        }
    }

    pub fn writeNull(self: *Client) !void {
        _ = try self.writer.interface.write("$-1\r\n");
    }

    pub fn writePrimitiveValue(self: *Client, value: PrimitiveValue) !void {
        switch (value) {
            .string => |str| try self.writeBulkString(str),
            .int => |i| try self.writeInt(i),
        }
    }
};
