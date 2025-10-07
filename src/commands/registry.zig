const std = @import("std");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const Store = @import("../store.zig").Store;
const aof = @import("../aof/aof.zig");
const resp = @import("./resp.zig");

pub const CommandError = error{
    WrongNumberOfArguments,
    InvalidArgument,
    UnknownCommand,
};

pub const CommandHandler = union(enum) {
    default: DefaultHandler,
    client_handler: ClientHander,
    store_handler: StoreHandler,
};

// No side-effects
pub const DefaultHandler = *const fn (writer: *std.Io.Writer, args: []const Value) anyerror!void;
// Requires client
pub const ClientHander = *const fn (client: *Client, args: []const Value) anyerror!void;
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

    pub fn executeCommandClient(
        self: *CommandRegistry,
        client: *Client,
        args: []const Value,
    ) !void {
        var buf: [4096]u8 = undefined;
        var sw = client.connection.stream.writer(&buf);
        const writer = &sw.interface;

        try self.executeCommand(writer, client, client.store, &client.server.aof_writer, args);

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

    pub fn executeCommand(
        self: *CommandRegistry,
        writer: *std.Io.Writer,
        client: *Client,
        store: *Store,
        aof_writer: *aof.Writer,
        args: []const Value,
    ) !void {
        if (args.len == 0) {
            return resp.writeError(writer, "ERR empty command");
        }

        const command_name = args[0].asSlice();

        var buf: [32]u8 = undefined;
        if (command_name.len > buf.len) return error.CommandTooLong;

        for (command_name, 0..) |c, i| {
            buf[i] = std.ascii.toUpper(c);
        }
        const upper_name = buf[0..command_name.len];

        for (command_name, 0..) |c, i| {
            upper_name[i] = std.ascii.toUpper(c);
        }

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
                    handler(client, args) catch |err| {
                        std.log.err("Handler for command '{s}' failed with error: {s}", .{
                            cmd_info.name,
                            @errorName(err),
                        });
                        resp.writeError(writer, "ERR while processing command") catch {};
                        return;
                    };
                },
                .store_handler => |handler| {
                    // If we haven't provided a store, this is an invariant failure
                    handler(writer, store, args) catch |err| {
                        std.log.err("Handler for command '{s}' failed with error: {s}", .{
                            cmd_info.name,
                            @errorName(err),
                        });
                        resp.writeError(writer, "ERR while processing command") catch {};
                        return;
                    };
                },
                .default => |handler| {
                    handler(writer, args) catch |err| {
                        std.log.err("Handler for command '{s}' failed with error: {s}", .{
                            cmd_info.name,
                            @errorName(err),
                        });
                        resp.writeError(writer, "ERR while processing command") catch {};
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
            resp.writeError(writer, "ERR unknown command") catch {};
        }
    }
};
