const std = @import("std");
const fmt = std.fmt;
const Io = std.Io;
const Reader = Io.Reader;
const Allocator = std.mem.Allocator;

const Parser = @This();

/// Largest bulk string accepted, matching Redis' default proto-max-bulk-len.
const max_bulk_len = 512 * 1024 * 1024;

// Represents a value in the RESP protocol, which is a bulk string.
pub const Value = struct {
    data: []const u8,

    pub inline fn as_slice(self: Value) []const u8 {
        return self.data;
    }

    pub inline fn as_int(self: Value) fmt.ParseIntError!i64 {
        return fmt.parseInt(i64, self.data, 10);
    }

    pub inline fn as_u64(self: Value) fmt.ParseIntError!u64 {
        return fmt.parseInt(u64, self.data, 10);
    }

    pub inline fn as_f64(self: Value) fmt.ParseFloatError!f64 {
        return fmt.parseFloat(f64, self.data);
    }

    pub inline fn as_usize(self: Value) fmt.ParseIntError!usize {
        return fmt.parseInt(usize, self.data, 10);
    }

    pub inline fn as_u16(self: Value) fmt.ParseIntError!u16 {
        return fmt.parseInt(u16, self.data, 10);
    }
};

// Represents a parsed command, which is an array of values.
// Uses small buffer optimization: stores first 6 args inline to avoid heap allocation
// for ~90% of Redis commands (GET, SET, DEL, INCR, etc.)
pub const Command = struct {
    // Small buffer optimization: stores first 6 args inline (no heap allocation)
    small_args_buf: [6]Value = undefined,
    small_count: u8 = 0,
    // Large args storage: only allocated when > 6 args
    large_args: ?std.ArrayList(Value) = null,
    allocator: Allocator,
    // False when arg data borrows the reader's buffer instead of `allocator`.
    owns_args: bool = true,

    pub fn init(allocator: Allocator) Command {
        return .{
            .small_args_buf = undefined,
            .small_count = 0,
            .large_args = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Command) void {
        // Free all argument data
        if (self.owns_args) {
            for (self.get_args()) |arg| {
                self.allocator.free(arg.data);
            }
        }
        // Free ArrayList if it was allocated
        if (self.large_args) |*list| {
            list.deinit(self.allocator);
        }
    }

    pub fn add_arg(self: *Command, value: Value) !void {
        if (self.large_args) |*list| {
            // Already using ArrayList
            try list.append(self.allocator, value);
        } else if (self.small_count < 6) {
            // Still room in small buffer
            self.small_args_buf[self.small_count] = value;
            self.small_count += 1;
        } else {
            // Need to transition to ArrayList
            var list: std.ArrayList(Value) = try .initCapacity(self.allocator, 7);
            list.appendSliceAssumeCapacity(self.small_args_buf[0..6]);
            list.appendAssumeCapacity(value);
            self.large_args = list;
        }
    }

    /// Returns all arguments as a slice
    pub fn get_args(self: *const Command) []const Value {
        if (self.large_args) |list| {
            return list.items;
        }
        return self.small_args_buf[0..self.small_count];
    }

    /// Returns the total number of arguments
    pub fn arg_count(self: *const Command) usize {
        if (self.large_args) |list| {
            return list.items.len;
        }
        return self.small_count;
    }

    /// Gets argument at index with bounds checking
    pub fn get_arg(self: *const Command, index: usize) ?Value {
        const args = self.get_args();
        if (index >= args.len) return null;
        return args[index];
    }

    /// Gets argument data slice at index with bounds checking
    pub fn get_arg_slice(self: *const Command, index: usize) ?[]const u8 {
        if (self.get_arg(index)) |arg| {
            return arg.data;
        }
        return null;
    }

    /// Pre-allocate capacity for known number of arguments (Redis-style with cap)
    pub fn ensure_capacity(self: *Command, capacity: usize) !void {
        if (capacity <= 6) {
            // Small buffer is sufficient
            return;
        }

        // Need large storage
        if (self.large_args == null) {
            var list: std.ArrayList(Value) = try .initCapacity(self.allocator, capacity);
            // Copy any existing args from small buffer
            if (self.small_count > 0) {
                list.appendSliceAssumeCapacity(self.small_args_buf[0..self.small_count]);
                self.small_count = 0; // Mark as moved
            }
            self.large_args = list;
        } else {
            try self.large_args.?.ensureTotalCapacity(self.allocator, capacity);
        }
    }
};

allocator: Allocator,

pub fn init(allocator: Allocator) Parser {
    return .{ .allocator = allocator };
}

/// Parses a RESP length (array count or bulk length): ASCII digits only, no
/// sign, prefix or separators. Returns null on anything else or overflow.
/// Hand-rolled because std.fmt.parseInt's generality (base detection, '_')
/// showed up as a large share of pipelined parse time.
fn parse_length(text: []const u8) ?usize {
    // 18 digits always fit in a u64 without overflow checks.
    if (text.len == 0 or text.len > 18) return null;
    var value: usize = 0;
    for (text) |c| {
        const digit = c -% '0';
        if (digit > 9) return null;
        value = value * 10 + digit;
    }
    return value;
}

pub const BufferedCommand = struct {
    command: Command,
    /// Bytes of `buffered` the command occupied, including its final CRLF.
    consumed: usize,
};

/// Parses one command from bytes that are already buffered, in a single pass.
/// Returns null if `buffered` does not yet hold a complete command (nothing is
/// consumed), and error.InvalidProtocol on malformed input.
///
/// Args borrow `buffered` (`Command.owns_args` is false): they stay valid only
/// while those bytes do, i.e. until the reader is refilled.
pub fn parse_buffered(self: *Parser, buffered: []const u8) !?BufferedCommand {
    const header_end = std.mem.indexOfScalar(u8, buffered, '\n') orelse return null;
    const line = try strip_crlf(buffered[0 .. header_end + 1]);
    if (line.len == 0) return error.InvalidProtocol;

    if (line[0] != '*') {
        if (line[0] == '$' or line[0] == '+' or line[0] == '-' or line[0] == ':') {
            return error.InvalidProtocol;
        }
        return .{ .command = try self.parse_inline_command(line, true), .consumed = header_end + 1 };
    }

    const count = parse_length(line[1..]) orelse return error.InvalidProtocol;
    var command = Command.init(self.allocator);
    command.owns_args = false;
    errdefer command.deinit();
    try command.ensure_capacity(@min(count, 1024));

    var pos = header_end + 1;
    for (0..count) |_| {
        const bulk_end = std.mem.indexOfScalarPos(u8, buffered, pos, '\n') orelse {
            command.deinit();
            return null;
        };
        const bulk_line = try strip_crlf(buffered[pos .. bulk_end + 1]);
        if (bulk_line.len == 0 or bulk_line[0] != '$') return error.InvalidProtocol;
        const len = parse_length(bulk_line[1..]) orelse return error.InvalidProtocol;
        if (len > max_bulk_len) return error.InvalidProtocol;

        const data_start = bulk_end + 1;
        if (buffered.len - data_start < len + 2) {
            command.deinit();
            return null;
        }
        const data_end = data_start + len;
        if (buffered[data_end] != '\r' or buffered[data_end + 1] != '\n') return error.InvalidProtocol;

        try command.add_arg(.{ .data = buffered[data_start..data_end] });
        pos = data_end + 2;
    }

    return .{ .command = command, .consumed = pos };
}

/// Returns `line_with_lf` without its trailing CRLF; RESP requires the CR.
fn strip_crlf(line_with_lf: []const u8) error{InvalidProtocol}![]const u8 {
    if (line_with_lf.len < 2 or line_with_lf[line_with_lf.len - 2] != '\r') return error.InvalidProtocol;
    return line_with_lf[0 .. line_with_lf.len - 2];
}

// Main parsing function. Supports both RESP array commands and inline commands:
// RESP: *<num>\r\n$<len>\r\n<data>\r\n ...
// Inline: CMD arg1 arg2 ... \r\n
// Uses Redis-style pre-allocation with 1024 cap to prevent DoS attacks
pub fn parse(self: *Parser, reader: *Reader) !Command {
    const line = try Parser.read_line(reader);

    if (line.len == 0) {
        return error.InvalidProtocol;
    }

    // RESP array command
    if (line[0] == '*') {
        return self.parse_resp_array(reader, line);
    }

    // Inline command: any line that doesn't start with a RESP type indicator
    if (line[0] != '$' and line[0] != '+' and line[0] != '-' and line[0] != ':') {
        return self.parse_inline_command(line, false);
    }

    return error.InvalidProtocol;
}

fn parse_resp_array(self: *Parser, reader: *Reader, line: []const u8) !Command {
    const count = parse_length(line[1..]) orelse return error.InvalidProtocol;

    // Redis-style: pre-allocate with safety cap at 1024 to prevent malicious requests
    // from allocating huge arrays (e.g., "*999999999\r\n")
    const initial_capacity = @min(count, 1024);
    var command = Command.init(self.allocator);
    errdefer command.deinit(); // Clean up on error to prevent memory leaks

    try command.ensure_capacity(initial_capacity);

    for (0..count) |_| {
        const bulk_line = try Parser.read_line(reader);
        if (bulk_line.len == 0 or bulk_line[0] != '$') {
            return error.InvalidProtocol;
        }

        const data = try self.read_bulk_data(reader, bulk_line);
        try command.add_arg(.{ .data = data });
    }

    return command;
}

/// Splits an inline command line on spaces. With `borrow`, args slice `line`
/// instead of being copied.
fn parse_inline_command(self: *Parser, line: []const u8, borrow: bool) !Command {
    var command = Command.init(self.allocator);
    command.owns_args = !borrow;
    errdefer command.deinit();

    // Split line by spaces (skip empty segments from multiple spaces)
    var start: usize = 0;
    while (start < line.len) {
        // Skip leading spaces
        while (start < line.len and line[start] == ' ') : (start += 1) {}
        if (start >= line.len) break;

        // Find end of argument
        var end = start;
        while (end < line.len and line[end] != ' ') : (end += 1) {}

        const arg = line[start..end];
        const data = if (borrow) arg else try self.allocator.dupe(u8, arg);
        try command.add_arg(.{ .data = data });

        start = end;
    }

    if (command.arg_count() == 0) {
        return error.InvalidProtocol;
    }

    return command;
}

// Reads bulk string data based on the length specified in the bulk_line.
fn read_bulk_data(self: *Parser, reader: *Reader, bulk_line: []const u8) ![]const u8 {
    // Null bulk strings ("$-1") are rejected along with other non-digit lengths.
    const len = parse_length(bulk_line[1..]) orelse return error.InvalidProtocol;
    if (len > max_bulk_len) return error.InvalidProtocol;

    const data = try self.allocator.alloc(u8, len);
    errdefer self.allocator.free(data);

    // Read exact number of bytes (uses buffered reading)
    try reader.readSliceAll(data);

    // Expect trailing CRLF after the bulk string payload
    const cr = try reader.takeByte();
    const lf = try reader.takeByte();
    if (cr != '\r' or lf != '\n') {
        return error.InvalidProtocol;
    }

    return data;
}

// Reads a RESP line terminated by CRLF. Returns slice of internal buffer
fn read_line(reader: *Reader) ![]const u8 {
    // Read until '\n' delimiter (inclusive, so \n is consumed)
    const line_with_crlf = reader.takeDelimiterInclusive('\n') catch |err| {
        if (err == error.ReadFailed) return error.EndOfStream;
        return err;
    };

    // RESP requires CRLF, so verify the line ends with \r\n
    if (line_with_crlf.len < 2 or
        line_with_crlf[line_with_crlf.len - 2] != '\r' or
        line_with_crlf[line_with_crlf.len - 1] != '\n')
    {
        return error.InvalidProtocol;
    }

    const line_len = line_with_crlf.len - 2; // Remove trailing \r\n

    return line_with_crlf[0..line_len];
}

const testing = std.testing;

test "parser read_line with CRLF" {
    const test_data = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    const line1 = try Parser.read_line(reader);
    try testing.expectEqualStrings("*3", line1);

    const line2 = try Parser.read_line(reader);
    try testing.expectEqualStrings("$3", line2);

    const line3 = try Parser.read_line(reader);
    try testing.expectEqualStrings("SET", line3);

    const line4 = try Parser.read_line(reader);
    try testing.expectEqualStrings("$3", line4);
}

test "parser full command with buffering" {
    const test_data = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 3), command.arg_count());
    try testing.expectEqualStrings("SET", command.get_args()[0].data);
    try testing.expectEqualStrings("key", command.get_args()[1].data);
    try testing.expectEqualStrings("value", command.get_args()[2].data);
}

test "parser read_line invalid protocol - missing CR" {
    const test_data = "*3\n$3\nSET\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    const result = Parser.read_line(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser read_line empty line" {
    const test_data = "\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    const line = try Parser.read_line(reader);
    try testing.expectEqual(@as(usize, 0), line.len);
}

test "parser read_line end of stream" {
    const test_data = "*3\r\n$3\r\nSET\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    _ = try Parser.read_line(reader); // *3
    _ = try Parser.read_line(reader); // $3
    _ = try Parser.read_line(reader); // SET

    const result = Parser.read_line(reader);
    try testing.expectError(error.EndOfStream, result);
}

test "parser parse invalid protocol - not starting with asterisk" {
    const test_data = "$3\r\nSET\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - bulk string not starting with dollar" {
    const test_data = "*1\r\n+OK\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - malformed array count" {
    const test_data = "*abc\r\n$3\r\nSET\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - malformed bulk length" {
    const test_data = "*1\r\n$xyz\r\nSET\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - null bulk string" {
    const test_data = "*1\r\n$-1\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - missing trailing CRLF after bulk data" {
    const test_data = "*1\r\n$3\r\nSET";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.EndOfStream, result);
}

test "parser parse invalid protocol - wrong trailing after bulk data" {
    const test_data = "*1\r\n$3\r\nSET\n\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse empty bulk string" {
    const test_data = "*2\r\n$3\r\nSET\r\n$0\r\n\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.arg_count());
    try testing.expectEqualStrings("SET", command.get_args()[0].data);
    try testing.expectEqualStrings("", command.get_args()[1].data);
}

test "parser parse single argument command" {
    const test_data = "*1\r\n$4\r\nPING\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 1), command.arg_count());
    try testing.expectEqualStrings("PING", command.get_args()[0].data);
}

test "parser parse command with special characters" {
    const test_data = "*2\r\n$3\r\nSET\r\n$12\r\nhello\nworld!\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.arg_count());
    try testing.expectEqualStrings("SET", command.get_args()[0].data);
    try testing.expectEqualStrings("hello\nworld!", command.get_args()[1].data);
}

test "parser parse command with unicode" {
    const test_data = "*2\r\n$3\r\nSET\r\n$12\r\nhello 世界\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.arg_count());
    try testing.expectEqualStrings("SET", command.get_args()[0].data);
    try testing.expectEqualStrings("hello 世界", command.get_args()[1].data);
}

test "parser parse multiple commands in sequence" {
    const test_data = "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n*3\r\n$3\r\nSET\r\n$4\r\nkey2\r\n$6\r\nvalue2\r\n";
    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    // First command
    var command1 = try parser.parse(reader);
    defer command1.deinit();
    try testing.expectEqual(@as(usize, 2), command1.arg_count());
    try testing.expectEqualStrings("GET", command1.get_args()[0].data);
    try testing.expectEqualStrings("key", command1.get_args()[1].data);

    // Second command
    var command2 = try parser.parse(reader);
    defer command2.deinit();
    try testing.expectEqual(@as(usize, 3), command2.arg_count());
    try testing.expectEqualStrings("SET", command2.get_args()[0].data);
    try testing.expectEqualStrings("key2", command2.get_args()[1].data);
    try testing.expectEqualStrings("value2", command2.get_args()[2].data);
}

test "parser parse large bulk string" {
    // Create a large value (1KB)
    var large_value: [1024]u8 = undefined;
    @memset(&large_value, 'X');

    var test_buf: [2048]u8 = undefined;
    const test_data = fmt.bufPrint(&test_buf, "*2\r\n$3\r\nSET\r\n$1024\r\n{s}\r\n", .{large_value}) catch unreachable;

    const fixed_reader = Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.arg_count());
    try testing.expectEqualStrings("SET", command.get_args()[0].data);
    try testing.expectEqual(@as(usize, 1024), command.get_args()[1].data.len);
    try testing.expectEqual(@as(u8, 'X'), command.get_args()[1].data[0]);
    try testing.expectEqual(@as(u8, 'X'), command.get_args()[1].data[1023]);
}

test "Value as_int positive number" {
    const value = Value{ .data = "12345" };
    const result = try value.as_int();
    try testing.expectEqual(@as(i64, 12345), result);
}

test "Value as_int negative number" {
    const value = Value{ .data = "-9876" };
    const result = try value.as_int();
    try testing.expectEqual(@as(i64, -9876), result);
}

test "Value as_int zero" {
    const value = Value{ .data = "0" };
    const result = try value.as_int();
    try testing.expectEqual(@as(i64, 0), result);
}

test "Value as_int invalid" {
    const value = Value{ .data = "not-a-number" };
    const result = value.as_int();
    try testing.expectError(error.InvalidCharacter, result);
}

test "Value as_int overflow" {
    const value = Value{ .data = "99999999999999999999" };
    const result = value.as_int();
    try testing.expectError(error.Overflow, result);
}

test "Value as_u64 positive number" {
    const value = Value{ .data = "18446744073709551615" };
    const result = try value.as_u64();
    try testing.expectEqual(@as(u64, 18446744073709551615), result);
}

test "Value as_u64 zero" {
    const value = Value{ .data = "0" };
    const result = try value.as_u64();
    try testing.expectEqual(@as(u64, 0), result);
}

test "Value as_u64 invalid negative" {
    const value = Value{ .data = "-1" };
    const result = value.as_u64();
    try testing.expectError(error.Overflow, result);
}

test "Value as_f64 positive float" {
    const value = Value{ .data = "3.14159" };
    const result = try value.as_f64();
    try testing.expectApproxEqAbs(@as(f64, 3.14159), result, 0.00001);
}

test "Value as_f64 negative float" {
    const value = Value{ .data = "-2.71828" };
    const result = try value.as_f64();
    try testing.expectApproxEqAbs(@as(f64, -2.71828), result, 0.00001);
}

test "Value as_f64 scientific notation" {
    const value = Value{ .data = "1.23e10" };
    const result = try value.as_f64();
    try testing.expectApproxEqAbs(@as(f64, 1.23e10), result, 1.0);
}

test "Value as_f64 invalid" {
    const value = Value{ .data = "not-a-float" };
    const result = value.as_f64();
    try testing.expectError(error.InvalidCharacter, result);
}

test "Value as_usize positive number" {
    const value = Value{ .data = "42" };
    const result = try value.as_usize();
    try testing.expectEqual(@as(usize, 42), result);
}

test "Value as_u16 small number" {
    const value = Value{ .data = "6379" };
    const result = try value.as_u16();
    try testing.expectEqual(@as(u16, 6379), result);
}

test "Value as_u16 max value" {
    const value = Value{ .data = "65535" };
    const result = try value.as_u16();
    try testing.expectEqual(@as(u16, 65535), result);
}

test "Value as_u16 overflow" {
    const value = Value{ .data = "65536" };
    const result = value.as_u16();
    try testing.expectError(error.Overflow, result);
}

test "Command init and add_arg" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    const data1 = try testing.allocator.dupe(u8, "GET");
    const data2 = try testing.allocator.dupe(u8, "mykey");

    try command.add_arg(.{ .data = data1 });
    try command.add_arg(.{ .data = data2 });

    try testing.expectEqual(@as(usize, 2), command.arg_count());
    try testing.expectEqualStrings("GET", command.get_args()[0].data);
    try testing.expectEqualStrings("mykey", command.get_args()[1].data);
}

test "Command small buffer optimization" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    // Add 6 args - should stay in small buffer
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "arg");
        try command.add_arg(.{ .data = data });
    }

    try testing.expectEqual(@as(usize, 6), command.arg_count());
    try testing.expect(command.large_args == null); // Should still be using small buffer
}

test "Command transition to large storage" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    // Add 7 args - should transition to ArrayList
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "arg");
        try command.add_arg(.{ .data = data });
    }

    try testing.expectEqual(@as(usize, 7), command.arg_count());
    try testing.expect(command.large_args != null); // Should be using ArrayList now
}

test "Command convenience methods" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    const data1 = try testing.allocator.dupe(u8, "GET");
    const data2 = try testing.allocator.dupe(u8, "my-key");

    try command.add_arg(.{ .data = data1 });
    try command.add_arg(.{ .data = data2 });

    // Test arg_count
    try testing.expectEqual(@as(usize, 2), command.arg_count());

    // Test get_arg
    try testing.expect(command.get_arg(0) != null);
    try testing.expect(command.get_arg(2) == null); // Out of bounds

    // Test get_arg_slice
    try testing.expectEqualStrings("GET", command.get_arg_slice(0).?);
    try testing.expectEqualStrings("my-key", command.get_arg_slice(1).?);
    try testing.expect(command.get_arg_slice(2) == null); // Out of bounds
}

test "Command ensure_capacity pre-allocation" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    // Pre-allocate for 10 args
    try command.ensure_capacity(10);

    // Should have allocated ArrayList since 10 > 6
    try testing.expect(command.large_args != null);

    // Add args without reallocation
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "arg");
        try command.add_arg(.{ .data = data });
    }

    try testing.expectEqual(@as(usize, 10), command.arg_count());
}

test "parser parse_buffered slices args and reports consumed bytes" {
    const first = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const test_data = first ++ "*1\r\n$4\r\nPING\r\n";
    var parser = Parser.init(testing.allocator);

    var parsed = (try parser.parse_buffered(test_data)).?;
    defer parsed.command.deinit();

    try testing.expect(!parsed.command.owns_args);
    try testing.expectEqual(first.len, parsed.consumed);
    try testing.expectEqualStrings("value", parsed.command.get_args()[2].data);
    const value_ptr = @intFromPtr(parsed.command.get_args()[2].data.ptr);
    try testing.expect(value_ptr >= @intFromPtr(test_data.ptr) and value_ptr < @intFromPtr(test_data.ptr) + test_data.len);

    var next = (try parser.parse_buffered(test_data[parsed.consumed..])).?;
    defer next.command.deinit();
    try testing.expectEqualStrings("PING", next.command.get_args()[0].data);
}

test "parser parse_buffered inline command" {
    var parser = Parser.init(testing.allocator);

    var parsed = (try parser.parse_buffered("SET key value\r\nGET key\r\n")).?;
    defer parsed.command.deinit();

    try testing.expectEqual(@as(usize, 3), parsed.command.arg_count());
    try testing.expectEqualStrings("value", parsed.command.get_args()[2].data);
    try testing.expectEqual(@as(usize, "SET key value\r\n".len), parsed.consumed);
}

test "parser parse_buffered returns null for every incomplete prefix" {
    // Includes >6 args so the large-args list is allocated (and freed) on the null path.
    const full = "*7\r\n$4\r\nMSET\r\n$1\r\na\r\n$1\r\n1\r\n$1\r\nb\r\n$1\r\n2\r\n$1\r\nc\r\n$2\r\n33\r\n";
    var parser = Parser.init(testing.allocator);

    for (0..full.len) |n| {
        try testing.expectEqual(@as(?BufferedCommand, null), try parser.parse_buffered(full[0..n]));
    }
    var parsed = (try parser.parse_buffered(full)).?;
    defer parsed.command.deinit();
    try testing.expectEqual(@as(usize, 7), parsed.command.arg_count());
    try testing.expectEqual(full.len, parsed.consumed);
}

test "parser parse_buffered rejects malformed framing" {
    const cases = [_][]const u8{
        "\r\n", // empty line
        "*1\n$4\r\nPING\r\n", // header without CR
        "*x\r\n", // non-numeric count
        "*-1\r\n", // negative count
        "*1\r\n+4\r\nPING\r\n", // bulk header not '$'
        "*1\r\n$-1\r\n", // null bulk string
        "*1\r\n$+4\r\nPING\r\n", // signed length
        "*1\r\n$4\r\nPINGXX", // missing CRLF after data
        "*1\r\n$536870913\r\n", // above max_bulk_len
        "$4\r\nPING\r\n", // RESP type that isn't an array
    };
    var parser = Parser.init(testing.allocator);
    for (cases) |case| {
        try testing.expectError(error.InvalidProtocol, parser.parse_buffered(case));
    }
}

test "parse_length accepts plain decimal only" {
    try testing.expectEqual(@as(?usize, 0), parse_length("0"));
    try testing.expectEqual(@as(?usize, 102400), parse_length("102400"));
    try testing.expectEqual(@as(?usize, 999_999_999_999_999_999), parse_length("999999999999999999"));
    try testing.expectEqual(@as(?usize, null), parse_length(""));
    try testing.expectEqual(@as(?usize, null), parse_length("1_000"));
    try testing.expectEqual(@as(?usize, null), parse_length("0x10"));
    try testing.expectEqual(@as(?usize, null), parse_length("-1"));
    try testing.expectEqual(@as(?usize, null), parse_length("+1"));
    try testing.expectEqual(@as(?usize, null), parse_length("1234567890123456789"));
}

test "parser parse bulk string larger than 64KB" {
    const value_len = 100 * 1024;
    const header = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$102400\r\n";
    const test_data = try testing.allocator.alloc(u8, header.len + value_len + 2);
    defer testing.allocator.free(test_data);
    @memcpy(test_data[0..header.len], header);
    @memset(test_data[header.len..][0..value_len], 'v');
    @memcpy(test_data[header.len + value_len ..], "\r\n");

    var reader: Reader = .fixed(test_data);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(&reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, value_len), command.get_args()[2].data.len);
}

test "parser rejects bulk length above max_bulk_len" {
    var reader: Reader = .fixed("*1\r\n$536870913\r\n");
    var parser = Parser.init(testing.allocator);

    try testing.expectError(error.InvalidProtocol, parser.parse(&reader));
}
