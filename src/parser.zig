const std = @import("std");

// Represents a value in the RESP protocol, which is a bulk string.
pub const Value = struct {
    data: []const u8,

    pub inline fn asSlice(self: Value) []const u8 {
        return self.data;
    }

    pub inline fn asInt(self: Value) std.fmt.ParseIntError!i64 {
        return std.fmt.parseInt(i64, self.data, 10);
    }

    pub inline fn asU64(self: Value) std.fmt.ParseIntError!u64 {
        return std.fmt.parseInt(u64, self.data, 10);
    }

    pub inline fn asF64(self: Value) std.fmt.ParseFloatError!f64 {
        return std.fmt.parseFloat(f64, self.data);
    }

    pub inline fn asUsize(self: Value) std.fmt.ParseIntError!usize {
        return std.fmt.parseInt(usize, self.data, 10);
    }

    pub inline fn asU16(self: Value) std.fmt.ParseIntError!u16 {
        return std.fmt.parseInt(u16, self.data, 10);
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Command {
        return .{
            .small_args_buf = undefined,
            .small_count = 0,
            .large_args = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Command) void {
        // Free all argument data
        const args = self.getArgs();
        for (args) |arg| {
            self.allocator.free(arg.data);
        }
        // Free ArrayList if it was allocated
        if (self.large_args) |*list| {
            list.deinit(self.allocator);
        }
    }

    pub fn addArg(self: *Command, value: Value) !void {
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
    pub fn getArgs(self: *const Command) []const Value {
        if (self.large_args) |list| {
            return list.items;
        }
        return self.small_args_buf[0..self.small_count];
    }

    /// Returns the total number of arguments
    pub fn argCount(self: *const Command) usize {
        if (self.large_args) |list| {
            return list.items.len;
        }
        return self.small_count;
    }

    /// Gets argument at index with bounds checking
    pub fn getArg(self: *const Command, index: usize) ?Value {
        const args = self.getArgs();
        if (index >= args.len) return null;
        return args[index];
    }

    /// Gets argument data slice at index with bounds checking
    pub fn getArgSlice(self: *const Command, index: usize) ?[]const u8 {
        if (self.getArg(index)) |arg| {
            return arg.data;
        }
        return null;
    }

    /// Pre-allocate capacity for known number of arguments (Redis-style with cap)
    pub fn ensureCapacity(self: *Command, capacity: usize) !void {
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

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    // Main parsing function. It expects a command to be a RESP array of bulk strings:
    // *<num>\r\n$<len>\r\n<data>\r\n ...
    // Uses Redis-style pre-allocation with 1024 cap to prevent DoS attacks
    pub fn parse(self: *Parser, reader: *std.Io.Reader) !Command {
        const line = try Parser.readLine(reader);

        if (line.len == 0 or line[0] != '*') {
            return error.InvalidProtocol;
        }

        const count = std.fmt.parseInt(usize, line[1..], 10) catch return error.InvalidProtocol;

        // Redis-style: pre-allocate with safety cap at 1024 to prevent malicious requests
        // from allocating huge arrays (e.g., "*999999999\r\n")
        const initial_capacity = @min(count, 1024);
        var command = Command.init(self.allocator);
        errdefer command.deinit(); // Clean up on error to prevent memory leaks

        try command.ensureCapacity(initial_capacity);

        for (0..count) |_| {
            const bulk_line = try Parser.readLine(reader);
            if (bulk_line.len == 0 or bulk_line[0] != '$') {
                return error.InvalidProtocol;
            }

            const data = try self.readBulkData(reader, bulk_line);
            try command.addArg(.{ .data = data });
        }

        return command;
    }

    // Reads bulk string data based on the length specified in the bulk_line.
    fn readBulkData(self: *Parser, reader: *std.Io.Reader, bulk_line: []const u8) ![]const u8 {
        const len = std.fmt.parseInt(i64, bulk_line[1..], 10) catch return error.InvalidProtocol;

        if (len < 0) {
            return error.InvalidProtocol; // Null bulk strings not supported in this example
        }

        const ulen: usize = @intCast(len);
        const data = try self.allocator.alloc(u8, ulen);
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
    fn readLine(reader: *std.Io.Reader) ![]const u8 {
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
};

const testing = std.testing;

test "parser readLine with CRLF" {
    const test_data = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    const line1 = try Parser.readLine(reader);
    try testing.expectEqualStrings("*3", line1);

    const line2 = try Parser.readLine(reader);
    try testing.expectEqualStrings("$3", line2);

    const line3 = try Parser.readLine(reader);
    try testing.expectEqualStrings("SET", line3);

    const line4 = try Parser.readLine(reader);
    try testing.expectEqualStrings("$3", line4);
}

test "parser full command with buffering" {
    const test_data = "*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 3), command.argCount());
    try testing.expectEqualStrings("SET", command.getArgs()[0].data);
    try testing.expectEqualStrings("key", command.getArgs()[1].data);
    try testing.expectEqualStrings("value", command.getArgs()[2].data);
}

test "parser readLine invalid protocol - missing CR" {
    const test_data = "*3\n$3\nSET\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    const result = Parser.readLine(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser readLine empty line" {
    const test_data = "\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    const line = try Parser.readLine(reader);
    try testing.expectEqual(@as(usize, 0), line.len);
}

test "parser readLine end of stream" {
    const test_data = "*3\r\n$3\r\nSET\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);

    _ = try Parser.readLine(reader); // *3
    _ = try Parser.readLine(reader); // $3
    _ = try Parser.readLine(reader); // SET

    const result = Parser.readLine(reader);
    try testing.expectError(error.EndOfStream, result);
}

test "parser parse invalid protocol - not starting with asterisk" {
    const test_data = "$3\r\nSET\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - bulk string not starting with dollar" {
    const test_data = "*1\r\n+OK\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - malformed array count" {
    const test_data = "*abc\r\n$3\r\nSET\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - malformed bulk length" {
    const test_data = "*1\r\n$xyz\r\nSET\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - null bulk string" {
    const test_data = "*1\r\n$-1\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse invalid protocol - missing trailing CRLF after bulk data" {
    const test_data = "*1\r\n$3\r\nSET";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.EndOfStream, result);
}

test "parser parse invalid protocol - wrong trailing after bulk data" {
    const test_data = "*1\r\n$3\r\nSET\n\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    const result = parser.parse(reader);
    try testing.expectError(error.InvalidProtocol, result);
}

test "parser parse empty bulk string" {
    const test_data = "*2\r\n$3\r\nSET\r\n$0\r\n\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.argCount());
    try testing.expectEqualStrings("SET", command.getArgs()[0].data);
    try testing.expectEqualStrings("", command.getArgs()[1].data);
}

test "parser parse single argument command" {
    const test_data = "*1\r\n$4\r\nPING\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 1), command.argCount());
    try testing.expectEqualStrings("PING", command.getArgs()[0].data);
}

test "parser parse command with special characters" {
    const test_data = "*2\r\n$3\r\nSET\r\n$12\r\nhello\nworld!\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.argCount());
    try testing.expectEqualStrings("SET", command.getArgs()[0].data);
    try testing.expectEqualStrings("hello\nworld!", command.getArgs()[1].data);
}

test "parser parse command with unicode" {
    const test_data = "*2\r\n$3\r\nSET\r\n$12\r\nhello 世界\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.argCount());
    try testing.expectEqualStrings("SET", command.getArgs()[0].data);
    try testing.expectEqualStrings("hello 世界", command.getArgs()[1].data);
}

test "parser parse multiple commands in sequence" {
    const test_data = "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n*3\r\n$3\r\nSET\r\n$4\r\nkey2\r\n$6\r\nvalue2\r\n";
    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    // First command
    var command1 = try parser.parse(reader);
    defer command1.deinit();
    try testing.expectEqual(@as(usize, 2), command1.argCount());
    try testing.expectEqualStrings("GET", command1.getArgs()[0].data);
    try testing.expectEqualStrings("key", command1.getArgs()[1].data);

    // Second command
    var command2 = try parser.parse(reader);
    defer command2.deinit();
    try testing.expectEqual(@as(usize, 3), command2.argCount());
    try testing.expectEqualStrings("SET", command2.getArgs()[0].data);
    try testing.expectEqualStrings("key2", command2.getArgs()[1].data);
    try testing.expectEqualStrings("value2", command2.getArgs()[2].data);
}

test "parser parse large bulk string" {
    // Create a large value (1KB)
    var large_value: [1024]u8 = undefined;
    @memset(&large_value, 'X');

    var test_buf: [2048]u8 = undefined;
    const test_data = std.fmt.bufPrint(&test_buf, "*2\r\n$3\r\nSET\r\n$1024\r\n{s}\r\n", .{large_value}) catch unreachable;

    const fixed_reader = std.Io.Reader.fixed(test_data);
    const reader = @constCast(&fixed_reader);
    var parser = Parser.init(testing.allocator);

    var command = try parser.parse(reader);
    defer command.deinit();

    try testing.expectEqual(@as(usize, 2), command.argCount());
    try testing.expectEqualStrings("SET", command.getArgs()[0].data);
    try testing.expectEqual(@as(usize, 1024), command.getArgs()[1].data.len);
    try testing.expectEqual(@as(u8, 'X'), command.getArgs()[1].data[0]);
    try testing.expectEqual(@as(u8, 'X'), command.getArgs()[1].data[1023]);
}

test "Value asInt positive number" {
    const value = Value{ .data = "12345" };
    const result = try value.asInt();
    try testing.expectEqual(@as(i64, 12345), result);
}

test "Value asInt negative number" {
    const value = Value{ .data = "-9876" };
    const result = try value.asInt();
    try testing.expectEqual(@as(i64, -9876), result);
}

test "Value asInt zero" {
    const value = Value{ .data = "0" };
    const result = try value.asInt();
    try testing.expectEqual(@as(i64, 0), result);
}

test "Value asInt invalid" {
    const value = Value{ .data = "not-a-number" };
    const result = value.asInt();
    try testing.expectError(error.InvalidCharacter, result);
}

test "Value asInt overflow" {
    const value = Value{ .data = "99999999999999999999" };
    const result = value.asInt();
    try testing.expectError(error.Overflow, result);
}

test "Value asU64 positive number" {
    const value = Value{ .data = "18446744073709551615" };
    const result = try value.asU64();
    try testing.expectEqual(@as(u64, 18446744073709551615), result);
}

test "Value asU64 zero" {
    const value = Value{ .data = "0" };
    const result = try value.asU64();
    try testing.expectEqual(@as(u64, 0), result);
}

test "Value asU64 invalid negative" {
    const value = Value{ .data = "-1" };
    const result = value.asU64();
    try testing.expectError(error.Overflow, result);
}

test "Value asF64 positive float" {
    const value = Value{ .data = "3.14159" };
    const result = try value.asF64();
    try testing.expectApproxEqAbs(@as(f64, 3.14159), result, 0.00001);
}

test "Value asF64 negative float" {
    const value = Value{ .data = "-2.71828" };
    const result = try value.asF64();
    try testing.expectApproxEqAbs(@as(f64, -2.71828), result, 0.00001);
}

test "Value asF64 scientific notation" {
    const value = Value{ .data = "1.23e10" };
    const result = try value.asF64();
    try testing.expectApproxEqAbs(@as(f64, 1.23e10), result, 1.0);
}

test "Value asF64 invalid" {
    const value = Value{ .data = "not-a-float" };
    const result = value.asF64();
    try testing.expectError(error.InvalidCharacter, result);
}

test "Value asUsize positive number" {
    const value = Value{ .data = "42" };
    const result = try value.asUsize();
    try testing.expectEqual(@as(usize, 42), result);
}

test "Value asUsize zero" {
    const value = Value{ .data = "0" };
    const result = try value.asUsize();
    try testing.expectEqual(@as(usize, 0), result);
}

test "Value asU16 small number" {
    const value = Value{ .data = "6379" };
    const result = try value.asU16();
    try testing.expectEqual(@as(u16, 6379), result);
}

test "Value asU16 max value" {
    const value = Value{ .data = "65535" };
    const result = try value.asU16();
    try testing.expectEqual(@as(u16, 65535), result);
}

test "Value asU16 overflow" {
    const value = Value{ .data = "65536" };
    const result = value.asU16();
    try testing.expectError(error.Overflow, result);
}

test "Value asSlice returns correct slice" {
    const value = Value{ .data = "hello world" };
    const result = value.asSlice();
    try testing.expectEqualStrings("hello world", result);
}

test "Command init and addArg" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    const data1 = try testing.allocator.dupe(u8, "GET");
    const data2 = try testing.allocator.dupe(u8, "mykey");

    try command.addArg(.{ .data = data1 });
    try command.addArg(.{ .data = data2 });

    try testing.expectEqual(@as(usize, 2), command.argCount());
    try testing.expectEqualStrings("GET", command.getArgs()[0].data);
    try testing.expectEqualStrings("mykey", command.getArgs()[1].data);
}

test "Command small buffer optimization" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    // Add 6 args - should stay in small buffer
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "arg");
        try command.addArg(.{ .data = data });
    }

    try testing.expectEqual(@as(usize, 6), command.argCount());
    try testing.expect(command.large_args == null); // Should still be using small buffer
}

test "Command transition to large storage" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    // Add 7 args - should transition to ArrayList
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "arg");
        try command.addArg(.{ .data = data });
    }

    try testing.expectEqual(@as(usize, 7), command.argCount());
    try testing.expect(command.large_args != null); // Should be using ArrayList now
}

test "Command convenience methods" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    const data1 = try testing.allocator.dupe(u8, "GET");
    const data2 = try testing.allocator.dupe(u8, "mykey");

    try command.addArg(.{ .data = data1 });
    try command.addArg(.{ .data = data2 });

    // Test argCount
    try testing.expectEqual(@as(usize, 2), command.argCount());

    // Test getArg
    try testing.expect(command.getArg(0) != null);
    try testing.expect(command.getArg(2) == null); // Out of bounds

    // Test getArgSlice
    try testing.expectEqualStrings("GET", command.getArgSlice(0).?);
    try testing.expectEqualStrings("mykey", command.getArgSlice(1).?);
    try testing.expect(command.getArgSlice(2) == null); // Out of bounds
}

test "Command ensureCapacity pre-allocation" {
    var command = Command.init(testing.allocator);
    defer command.deinit();

    // Pre-allocate for 10 args
    try command.ensureCapacity(10);

    // Should have allocated ArrayList since 10 > 6
    try testing.expect(command.large_args != null);

    // Add args without reallocation
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const data = try testing.allocator.dupe(u8, "arg");
        try command.addArg(.{ .data = data });
    }

    try testing.expectEqual(@as(usize, 10), command.argCount());
}
