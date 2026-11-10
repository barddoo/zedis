const std = @import("std");
const Client = @import("../app/client.zig").Client;
const Value = @import("../protocol/parser.zig").Value;
const Store = @import("../storage/store.zig").Store;
const resp = @import("../protocol/resp.zig");

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
    /// Redis' `CMD_DENYOOM`: reject with `-OOM` when the memory budget is
    /// exhausted. Commands that only free memory (DEL, LPOP, ...) leave it off.
    denyoom: bool = false,
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

    /// Whether `name` (any case) is a registered command.
    pub fn knows_command(self: *CommandRegistry, name: []const u8) bool {
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return false;
        return self.commands.contains(std.ascii.upperString(&buf, name));
    }

    pub fn should_write_to_aof(self: *CommandRegistry, name: []const u8) bool {
        var buf: [32]u8 = undefined;
        if (name.len > buf.len) return false;
        const upper_name = std.ascii.upperString(&buf, name);
        if (self.commands.get(upper_name)) |cmd_info| {
            return cmd_info.write_to_aof;
        }
        return false;
    }

    /// Redis' reply when a `CMD_DENYOOM` command cannot get memory.
    pub const oom_error_message = "OOM command not allowed when used memory > 'maxmemory'.";

    fn handle_command_error(writer: *std.Io.Writer, command_name: []const u8, err: anyerror) void {
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
            error.DocumentExists => "ERR document already exists",
            error.DocumentNotFound => "ERR no such document",
            error.FieldNotFound => "ERR unknown field",
            error.UnsupportedVectorAlgorithm => "ERR unsupported vector index algorithm",
            error.SyntaxError => "ERR syntax error",
            error.InvalidArgument => "ERR invalid argument",
            error.QuerySyntax => "ERR invalid query syntax",
            error.UnknownField => "ERR unknown field",
            error.MissingParam => "ERR missing query parameter",
            error.CommandTimeout => "TIMEOUT command exceeded the configured time limit",
            error.OutOfMemory => oom_error_message,
            else => blk: {
                std.log.err("Handler for command '{s}' failed with error: {s}", .{
                    command_name,
                    @errorName(err),
                });
                break :blk "ERR while processing command";
            },
        };
        resp.write_error(writer, msg) catch {};
    }

    pub fn execute_command_client(
        self: *CommandRegistry,
        client: *Client,
        writer: *std.Io.Writer,
        args: []const Value,
    ) !void {
        _ = try self.execute_command(writer, client, client.get_current_store(), args);

        try writer.flush();
    }

    pub fn execute_command_aof(
        self: *CommandRegistry,
        store: *Store,
        args: []const Value,
    ) !void {
        var dummy_client: Client = undefined;
        dummy_client.authenticated = true;
        dummy_client.protocol_version = 2;
        var discarding = std.Io.Writer.Discarding.init(&.{});
        // We should only be calling this command from the aof, so auth is assumed.
        // We should not be calling commands that require a real client.
        _ = try self.execute_command(&discarding.writer, &dummy_client, store, args);
    }

    /// Returns true when the command ran, false when it was rejected or its
    /// handler failed. The reply is always written; the return value feeds
    /// `commandstats`/`errorstats` and the failure counters.
    pub fn execute_command(
        self: *CommandRegistry,
        writer: *std.Io.Writer,
        client: *Client,
        store: *Store,
        args: []const Value,
    ) !bool {
        if (args.len == 0) {
            resp.write_error(writer, "ERR empty command") catch {};
            return false;
        }

        const command_name = args[0].as_slice();

        var buf: [32]u8 = undefined;
        if (command_name.len > buf.len) return error.CommandTooLong;
        const upper_name = std.ascii.upperString(&buf, command_name);

        resp.version = client.protocol_version;

        // Skip auth check for commands that don't need it. HELLO carries its
        // own AUTH option and checks credentials itself.
        if (!std.mem.eql(u8, upper_name, "AUTH") and
            !std.mem.eql(u8, upper_name, "HELLO") and
            !std.mem.eql(u8, upper_name, "PING") and
            !client.is_authenticated())
        {
            resp.write_error(writer, "NOAUTH Authentication required") catch {};
            return false;
        }

        if (self.get(upper_name)) |cmd_info| {
            // Validate argument count
            if (args.len < cmd_info.min_args) {
                resp.write_error(writer, "ERR wrong number of arguments") catch {};
                return false;
            }
            if (cmd_info.max_args) |max_args| {
                if (args.len > max_args) {
                    resp.write_error(writer, "ERR wrong number of arguments") catch {};
                    return false;
                }
            }

            switch (cmd_info.handler) {
                .client_handler => |handler| {
                    // If we haven't provided a client, this is an invariant failure
                    handler(client, args, writer) catch |err| {
                        handle_command_error(writer, cmd_info.name, err);
                        return false;
                    };
                },
                .store_handler => |handler| {
                    // If we haven't provided a store, this is an invariant failure
                    handler(writer, store, args) catch |err| {
                        handle_command_error(writer, cmd_info.name, err);
                        return false;
                    };
                },
                .default => |handler| {
                    handler(writer, args) catch |err| {
                        handle_command_error(writer, cmd_info.name, err);
                        return false;
                    };
                },
            }
            return true;
        } else {
            resp.write_error(writer, "ERR unknown command") catch {};
            return false;
        }
    }
};

test "handle_command_error writes a single error code prefix" {
    var buffer: [256]u8 = undefined;

    var writer: std.Io.Writer = .fixed(&buffer);
    CommandRegistry.handle_command_error(&writer, "INCR", error.Overflow);
    try std.testing.expectEqualStrings("-ERR increment or decrement would overflow\r\n", writer.buffered());

    writer = .fixed(&buffer);
    CommandRegistry.handle_command_error(&writer, "LPUSH", error.WrongType);
    try std.testing.expectEqualStrings("-WRONGTYPE Operation against a key holding the wrong kind of value\r\n", writer.buffered());

    writer = .fixed(&buffer);
    CommandRegistry.handle_command_error(&writer, "SET", error.OutOfMemory);
    try std.testing.expectEqualStrings("-OOM command not allowed when used memory > 'maxmemory'.\r\n", writer.buffered());
}

test "CMD_DENYOOM covers allocating writes and leaves freeing commands alone" {
    const init_registry = @import("init_registry.zig").init_registry;
    var registry = try init_registry(std.testing.allocator);
    defer registry.deinit();

    for ([_][]const u8{ "SET", "MSET", "LPUSH", "RPUSH", "LSET", "APPEND", "INCR", "BF.ADD", "TS.ADD" }) |name| {
        try std.testing.expect(registry.get(name).?.denyoom);
    }
    for ([_][]const u8{ "GET", "DEL", "LPOP", "RPOP", "FLUSHDB", "EXPIRE", "PERSIST" }) |name| {
        try std.testing.expect(!registry.get(name).?.denyoom);
    }
}

test "write commands are logged to the AOF and reads are not" {
    const init_registry = @import("init_registry.zig").init_registry;
    var registry = try init_registry(std.testing.allocator);
    defer registry.deinit();

    for ([_][]const u8{ "SET", "DEL", "UNLINK", "RENAME", "LPUSH", "rpush", "LPOP", "RPOP", "LSET", "EXPIRE", "PEXPIRE", "SETEX", "PEXPIREAT" }) |name| {
        try std.testing.expect(registry.should_write_to_aof(name));
    }
    for ([_][]const u8{ "GET", "LLEN", "LINDEX", "LRANGE", "EXISTS", "PTTL", "SCAN" }) |name| {
        try std.testing.expect(!registry.should_write_to_aof(name));
    }
}
