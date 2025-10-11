const std = @import("std");
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const resp = @import("../commands/resp.zig");

// PING command implementation
pub fn ping(writer: *std.Io.Writer, args: []const Value) !void {
    if (args.len == 1) {
        try resp.writeSimpleString(writer, "PONG");
    } else {
        try resp.writeBulkString(writer, args[1].asSlice());
    }
}

// ECHO command implementation
pub fn echo(writer: *std.Io.Writer, args: []const Value) !void {
    try resp.writeBulkString(writer, args[1].asSlice());
}

// QUIT command implementation
pub fn quit(client: *Client, args: []const Value) !void {
    var sw = client.connection.stream.writer(&.{});
    const writer = &sw.interface;
    _ = args; // Unused parameter
    try resp.writeOK(writer);
    client.connection.stream.close();
}

pub fn auth(client: *Client, args: []const Value) !void {
    var sw = client.connection.stream.writer(&.{});
    const writer = &sw.interface;
    const password = args[1].asSlice();

    if (!client.server.config.requiresAuth()) {
        return error.AuthNoPasswordSet;
    }

    if (std.mem.eql(u8, password, client.server.config.requirepass.?)) {
        client.authenticated = true;
        try resp.writeOK(writer);
    } else {
        client.authenticated = false;
        return error.AuthInvalidPassword;
    }
}

// SELECT command implementation - switch database
pub fn select(client: *Client, args: []const Value) !void {
    var sw = client.connection.stream.writer(&.{});
    const writer = &sw.interface;

    const db_str = args[1].asSlice();
    const db_index = std.fmt.parseInt(u8, db_str, 10) catch {
        return error.InvalidDatabaseIndex;
    };

    if (db_index >= 16) {
        return error.InvalidDatabaseIndex;
    }

    client.current_db = db_index;
    try resp.writeOK(writer);
}

// HELP command implementation
pub fn help(writer: *std.Io.Writer, args: []const Value) !void {
    _ = args; // Unused parameter
    const help_text =
        \\Zedis Server Commands:
        \\
        \\Connection Commands:
        \\  PING [message]       - Ping the server
        \\  ECHO <message>       - Echo the given string
        \\  SELECT <index>       - Select database (0-15)
        \\  QUIT                 - Close the connection
        \\  HELP                 - Show this help message
        \\
        \\String Commands:
        \\  SET <key> <value>    - Set string value of a key
        \\  GET <key>            - Get string value of a key
        \\  INCR <key>           - Increment the value of a key
        \\  DECR <key>           - Decrement the value of a key
    ;

    try resp.writeBulkString(writer, help_text);
}
