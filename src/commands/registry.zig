const std = @import("std");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const Store = @import("../store.zig").Store;
const aof = @import("../aof/aof.zig");
const resp = @import("./resp.zig");
const error_handler = @import("../error_handler.zig");
const ClientError = error_handler.ClientError;
const handleCommandError = error_handler.handleCommandError;

pub const CommandError = error{
    WrongNumberOfArguments,
    InvalidArgument,
    UnknownCommand,
    WrongType,
    ValueNotInteger,
    InvalidFloat,
    Overflow,
    KeyNotFound,
    IndexOutOfRange,
    NoSuchKey,
    AuthNoPasswordSet,
    AuthInvalidPassword,
    InvalidDatabaseIndex,
};

pub const CommandHandler = union(enum) {
    default: DefaultHandler,
    client_handler: ClientHandler,
    store_handler: StoreHandler,
};

// No side-effects
pub const DefaultHandler = *const fn (writer: *std.Io.Writer, args: []const Value) anyerror!void;
// Requires client
pub const ClientHandler = *const fn (client: *Client, args: []const Value, writer: *std.Io.Writer) anyerror!void;
// Requires store
pub const StoreHandler = *const fn (writer: *std.Io.Writer, store: *Store, args: []const Value) anyerror!void;

/// Routing strategy for commands in multi-shard architecture
/// Inspired by DragonflyDB's shared-nothing design
pub const CommandRoutingType = enum {
    single_key, // Route to one shard based on hash(key) % num_shards
    multi_key, // Broadcast to all shards, aggregate results (coordinator pattern)
    keyless, // Execute on client thread (no key routing)
    pubsub, // Execute on client thread (pub/sub operations)
    client_only, // Execute on client thread (AUTH, SELECT, PING, etc)
};

pub const CommandInfo = struct {
    name: []const u8,
    handler: CommandHandler,
    min_args: usize,
    max_args: ?usize, // null means unlimited
    description: []const u8,
    write_to_aof: bool,
    routing_type: CommandRoutingType,
    key_arg_index: ?usize, // Which argument is the key (usually 1), null for multi/keyless
};

// Command registry that maps command names to their handlers
pub const CommandRegistry = struct {
    commands: std.StringHashMap(CommandInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommandRegistry {
        return .{
            .commands = std.StringHashMap(CommandInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandRegistry) void {
        self.commands.deinit();
    }

    /// Clone the registry for thread-safe concurrent access
    pub fn clone(self: *const CommandRegistry, allocator: std.mem.Allocator) !CommandRegistry {
        var new_registry = CommandRegistry.init(allocator);

        // Copy all command entries from original registry
        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            try new_registry.commands.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        return new_registry;
    }

    pub fn register(self: *CommandRegistry, info: CommandInfo) !void {
        try self.commands.put(info.name, info);
    }

    pub fn get(self: *CommandRegistry, name: []const u8) ?CommandInfo {
        // Fast path: try exact match first (for already-uppercase names)
        if (self.commands.get(name)) |cmd| {
            return cmd;
        }

        // Normalize to uppercase for case-insensitive lookup (single pass)
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return null;

        for (name, 0..) |c, i| {
            buf[i] = std.ascii.toUpper(c);
        }

        return self.commands.get(buf[0..name.len]);
    }

    pub fn executeCommandClient(
        self: *CommandRegistry,
        client: *Client,
        writer: *std.Io.Writer,
        args: []const Value,
    ) !void {
        try self.executeCommand(writer, client, client.getCurrentStore(), &client.server.aof_writer, args);

        try writer.flush();
    }

    pub fn executeCommandAof(
        self: *CommandRegistry,
        store: *Store,
        args: []const Value,
    ) !void {
        var dummy_client: Client = undefined;
        dummy_client.authenticated = true;
        const discarding = std.Io.Writer.Discarding.init(&.{});
        var writer = discarding.writer;
        var aof_writer: aof.Writer = try .init(false);
        // We should only be calling this command from the aof, so auth is assumed.
        // We should not be calling commands that require a real client.
        try self.executeCommand(&writer, &dummy_client, store, &aof_writer, args);
    }

    /// Execute command on shard thread (shared-nothing execution)
    /// Only executes store_handler commands since shards don't have full client context
    pub fn executeCommandShard(
        self: *CommandRegistry,
        writer: *std.Io.Writer,
        store: *Store,
        args: []const Value,
    ) !void {
        if (args.len == 0) {
            return error.EmptyCommand;
        }

        const command_name = args[0].asSlice();

        if (self.get(command_name)) |cmd_info| {
            // Validate argument count
            if (args.len < cmd_info.min_args) {
                return error.WrongNumberOfArguments;
            }
            if (cmd_info.max_args) |max_args| {
                if (args.len > max_args) {
                    return error.WrongNumberOfArguments;
                }
            }

            // Only execute store_handler commands (shards don't have clients)
            switch (cmd_info.handler) {
                .store_handler => |handler| {
                    handler(writer, store, args) catch |err| {
                        handleCommandError(writer, cmd_info.name, err);
                        return;
                    };
                },
                else => {
                    // This should never happen in shard context
                    return error.CommandNotSupportedInShard;
                },
            }
        } else {
            return error.UnknownCommand;
        }
    }

    pub fn executeCommand(
        self: *CommandRegistry,
        writer: *std.Io.Writer,
        client: *Client,
        store: *Store,
        aof_writer: *aof.Writer,
        args: []const Value,
    ) !void {
        if (args.len == 0) {
            return error.EmptyCommand;
        }

        const command_name = args[0].asSlice();

        // Skip auth check for commands that don't need it (case-insensitive)
        if (!std.ascii.eqlIgnoreCase(command_name, "AUTH") and
            !std.ascii.eqlIgnoreCase(command_name, "PING") and
            !client.isAuthenticated())
        {
            return error.AuthenticationRequired;
        }

        if (self.get(command_name)) |cmd_info| {
            // Validate argument count
            if (args.len < cmd_info.min_args) {
                return error.WrongNumberOfArguments;
            }
            if (cmd_info.max_args) |max_args| {
                if (args.len > max_args) {
                    return error.WrongNumberOfArguments;
                }
            }

            switch (cmd_info.handler) {
                .client_handler => |handler| {
                    // If we haven't provided a client, this is an invariant failure
                    handler(client, args, writer) catch |err| {
                        handleCommandError(writer, cmd_info.name, err);
                        return;
                    };
                },
                .store_handler => |handler| {
                    // If we haven't provided a store, this is an invariant failure
                    handler(writer, store, args) catch |err| {
                        handleCommandError(writer, cmd_info.name, err);
                        return;
                    };
                },
                .default => |handler| {
                    handler(writer, args) catch |err| {
                        handleCommandError(writer, cmd_info.name, err);
                        return;
                    };
                },
            }
            if (aof_writer.enabled and cmd_info.write_to_aof) {
                try resp.writeListLen(aof_writer.writer(), args.len);
                for (args) |arg| {
                    try resp.writeBulkString(aof_writer.writer(), arg.asSlice());
                }
            }
        } else {
            return error.UnknownCommand;
        }
    }
};
