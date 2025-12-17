const std = @import("std");
const testing = std.testing;
const error_handler = @import("error_handler.zig");
const Io = std.Io;
const Writer = Io.Writer;
const ClientError = error_handler.ClientError;

test "UnknownCommand error has single ERR prefix" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "INVALID", ClientError.UnknownCommand);

    const output = writer.buffered();

    // Should be "-ERR unknown command\r\n"
    // NOT "-ERR ERR unknown command\r\n"
    try testing.expect(std.mem.startsWith(u8, output, "-ERR "));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 2, "ERR"));
    try testing.expectEqualStrings("-ERR unknown command\r\n", output);
}

test "ProtocolError has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "TEST", ClientError.ProtocolError);

    try testing.expectEqualStrings("-ERR protocol error\r\n", writer.buffered());
}

test "CommandTooLong has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "VERYLONGCOMMAND", ClientError.CommandTooLong);

    try testing.expectEqualStrings("-ERR command name too long\r\n", writer.buffered());
}

test "AuthenticationRequired has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "GET", ClientError.AuthenticationRequired);

    try testing.expectEqualStrings("-ERR NOAUTH Authentication required\r\n", writer.buffered());
}

test "EmptyCommand has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "", ClientError.EmptyCommand);

    try testing.expectEqualStrings("-ERR empty command\r\n", writer.buffered());
}

test "WrongType error has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "GET", error.WrongType);

    try testing.expectEqualStrings("-ERR WRONGTYPE Operation against a key holding the wrong kind of value\r\n", writer.buffered());
}

test "ValueNotInteger error has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "INCR", error.ValueNotInteger);

    try testing.expectEqualStrings("-ERR value is not an integer or out of range\r\n", writer.buffered());
}

test "InvalidDatabaseIndex error has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "SELECT", error.InvalidDatabaseIndex);

    try testing.expectEqualStrings("-ERR invalid database index (must be 0-15)\r\n", writer.buffered());
}

test "WrongNumberOfArguments error has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "SET", error.WrongNumberOfArguments);

    try testing.expectEqualStrings("-ERR wrong number of arguments\r\n", writer.buffered());
}

test "AuthInvalidPassword error has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "AUTH", error.AuthInvalidPassword);

    try testing.expectEqualStrings("-ERR invalid password\r\n", writer.buffered());
}

test "EnqueueFailed error has correct format" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    error_handler.handleCommandError(&writer, "SET", ClientError.EnqueueFailed);

    try testing.expectEqualStrings("-ERR failed to enqueue command\r\n", writer.buffered());
}

test "all error messages start with -ERR prefix" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const errors = [_]anyerror{
        ClientError.UnknownCommand,
        ClientError.ProtocolError,
        ClientError.CommandTooLong,
        ClientError.EmptyCommand,
        error.WrongType,
        error.ValueNotInteger,
    };

    for (errors) |err| {
        @memset(&buffer, 0);
        writer = Writer.fixed(&buffer);

        error_handler.handleCommandError(&writer, "TEST", err);

        const output = writer.buffered();
        try testing.expect(std.mem.startsWith(u8, output, "-ERR "));
        try testing.expect(std.mem.endsWith(u8, output, "\r\n"));
    }
}

test "error messages do not have double ERR prefix" {
    var buffer: [4096]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const errors = [_]anyerror{
        ClientError.UnknownCommand,
        ClientError.ProtocolError,
        ClientError.CommandTooLong,
        ClientError.EmptyCommand,
        ClientError.AuthenticationRequired,
        error.WrongType,
        error.ValueNotInteger,
        error.InvalidDatabaseIndex,
    };

    for (errors) |err| {
        @memset(&buffer, 0);
        writer = Writer.fixed(&buffer);

        error_handler.handleCommandError(&writer, "TEST", err);

        const output = writer.buffered();

        // Count occurrences of "ERR" - should only be 1
        var count: usize = 0;
        var i: usize = 0;
        while (i + 3 <= output.len) : (i += 1) {
            if (std.mem.eql(u8, output[i .. i + 3], "ERR")) {
                count += 1;
            }
        }

        try testing.expectEqual(@as(usize, 1), count);
    }
}
