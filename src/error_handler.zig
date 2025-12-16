const std = @import("std");
const resp = @import("./commands/resp.zig");

/// Client-specific errors for command routing and execution
pub const ClientError = error{
    CommandTooLong,
    UnknownCommand,
    InvalidKeyIndex,
    EnqueueFailed,
    CommandFailed,
    ShardCommandFailed,
    ProtocolError,
    EmptyCommand,
    CommandNotSupportedInShard,
    AuthenticationRequired,
};

/// Centralized error handling - maps errors to RESP error messages
pub fn handleCommandError(writer: *std.Io.Writer, command_name: []const u8, err: anyerror) void {
    const msg = switch (err) {
        // Command execution errors
        error.WrongType => "WRONGTYPE Operation against a key holding the wrong kind of value",
        error.ValueNotInteger => "value is not an integer or out of range",
        error.InvalidFloat => "value is not a valid float",
        error.Overflow => "increment or decrement would overflow",
        error.KeyNotFound => "no such key",
        error.IndexOutOfRange => "index out of range",
        error.NoSuchKey => "no such key",
        error.AuthNoPasswordSet => "Client sent AUTH, but no password is set",
        error.AuthInvalidPassword => "invalid password",
        error.InvalidDatabaseIndex => "invalid database index (must be 0-15)",
        error.AlreadyExists => "key already exists",
        error.TSDB_DuplicateTimestamp => "duplicate timestamp",
        // Client routing errors
        error.CommandTooLong => "command name too long",
        error.UnknownCommand => "unknown command",
        error.InvalidKeyIndex => "invalid key index",
        error.EnqueueFailed => "failed to enqueue command",
        error.CommandFailed => "command failed",
        error.ShardCommandFailed => "command failed on shard",
        error.ProtocolError => "protocol error",
        error.EmptyCommand => "empty command",
        error.CommandNotSupportedInShard => "command not supported in shard",
        error.WrongNumberOfArguments => "wrong number of arguments",
        error.AuthenticationRequired => "NOAUTH Authentication required",
        else => blk: {
            std.log.err("Handler for command '{s}' failed with error: {s}", .{
                command_name,
                @errorName(err),
            });
            break :blk "while processing command";
        },
    };
    resp.writeError(writer, msg) catch {};
}
