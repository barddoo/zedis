const std = @import("std");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const Store = @import("../store.zig").Store;
const resp = @import("./resp.zig");

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

pub const CommandInfo = struct {
    name: []const u8,
    handler: CommandHandler,
    min_args: usize,
    max_args: ?usize, // null means unlimited
    description: []const u8,
    write_to_aof: bool,
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

    pub fn register(self: *CommandRegistry, info: CommandInfo) !void {
        try self.commands.put(info.name, info);
    }

    pub fn get(self: *CommandRegistry, name: []const u8) ?CommandInfo {
        return self.commands.get(name);
    }

    pub fn shouldWriteToAof(self: *CommandRegistry, name: []const u8) bool {
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return false;
        const upper_name = std.ascii.upperString(&buf, name);
        if (self.commands.get(upper_name)) |cmd_info| {
            return cmd_info.write_to_aof;
        }
        return false;
    }

    fn handleCommandError(writer: *std.Io.Writer, command_name: []const u8, err: anyerror) void {
        const msg = switch (err) {
            error.WrongType => "WRONGTYPE Operation against a key holding the wrong kind of value",
            error.ValueNotInteger => "ERR value is not an integer or out of range",
            error.InvalidFloat => "ERR value is not a valid float",
            error.Overflow => "ERR increment or decrement would overflow",
            error.KeyNotFound => "ERR no such key",
            error.IndexOutOfRange => "ERR index out of range",
            error.NoSuchKey => "ERR no such key",
            error.AuthNoPasswordSet => "ERR Client sent AUTH, but no password is set",
            error.AuthInvalidPassword => "ERR invalid password",
            error.AlreadyExists => "ERR key already exists",
            error.TSDB_DuplicateTimestamp => "ERR duplicate timestamp",
            else => blk: {
                std.log.err("Handler for command '{s}' failed with error: {s}", .{
                    command_name,
                    @errorName(err),
                });
                break :blk "ERR while processing command";
            },
        };
        resp.writeError(writer, msg) catch {};
    }

    pub fn executeCommandClient(
        self: *CommandRegistry,
        client: *Client,
        writer: *std.Io.Writer,
        args: []const Value,
    ) !void {
        try self.executeCommand(writer, client, client.getCurrentStore(), args);

        try writer.flush();
    }

    pub fn executeCommandAof(
        self: *CommandRegistry,
        store: *Store,
        args: []const Value,
    ) !void {
        var dummy_client: Client = undefined;
        dummy_client.authenticated = true;
        var discarding = std.Io.Writer.Discarding.init(&.{});
        // We should only be calling this command from the aof, so auth is assumed.
        // We should not be calling commands that require a real client.
        try self.executeCommand(&discarding.writer, &dummy_client, store, args);
    }

    pub fn executeCommand(
        self: *CommandRegistry,
        writer: *std.Io.Writer,
        client: *Client,
        store: *Store,
        args: []const Value,
    ) !void {
        if (args.len == 0) {
            return resp.writeError(writer, "ERR empty command");
        }

        const command_name = args[0].asSlice();

        var buf: [32]u8 = undefined;
        if (command_name.len > buf.len) return error.CommandTooLong;
        const upper_name = std.ascii.upperString(&buf, command_name);

        // Skip auth check for commands that don't need it
        if (!std.mem.eql(u8, upper_name, "AUTH") and
            !std.mem.eql(u8, upper_name, "PING") and
            !client.isAuthenticated())
        {
            return resp.writeError(writer, "NOAUTH Authentication required");
        }

        if (self.get(upper_name)) |cmd_info| {
            // Validate argument count
            if (args.len < cmd_info.min_args) {
                return resp.writeError(writer, "ERR wrong number of arguments");
            }
            if (cmd_info.max_args) |max_args| {
                if (args.len > max_args) {
                    return resp.writeError(writer, "ERR wrong number of arguments");
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
        } else {
            resp.writeError(writer, "ERR unknown command") catch {};
        }
    }
};
