const std = @import("std");

// Represents a value in the RESP protocol, which is a bulk string.
pub const Value = struct {
    data: []const u8,

    pub fn asSlice(self: Value) []const u8 {
        return self.data;
    }

    pub fn asInt(self: Value) std.fmt.ParseIntError!i64 {
        return std.fmt.parseInt(i64, self.data, 10);
    }

    pub fn asU64(self: Value) std.fmt.ParseIntError!u64 {
        return std.fmt.parseInt(u64, self.data, 10);
    }

    pub fn asF64(self: Value) std.fmt.ParseFloatError!f64 {
        return std.fmt.parseFloat(f64, self.data);
    }

    pub fn asUsize(self: Value) std.fmt.ParseIntError!usize {
        return std.fmt.parseInt(usize, self.data, 10);
    }

    pub fn asU16(self: Value) std.fmt.ParseIntError!u16 {
        return std.fmt.parseInt(u16, self.data, 10);
    }
};

// Represents a parsed command, which is an array of values.
pub const Command = struct {
    args: std.ArrayList(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Command {
        return Command{
            .args = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Command) void {
        for (self.args.items) |arg| {
            self.allocator.free(arg.data);
        }
        self.args.deinit(self.allocator);
    }

    pub fn addArg(self: *Command, value: Value) !void {
        try self.args.append(self.allocator, value);
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    line_buf: [1024 * 2]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    // Main parsing function. It expects a command to be a RESP array of bulk strings:
    // *<num>\r\n$<len>\r\n<data>\r\n ...
    pub fn parse(self: *Parser, reader: *std.Io.Reader) !Command {
        const line = try self.readLine(reader);

        if (line.len == 0 or line[0] != '*') {
            return error.InvalidProtocol;
        }

        const count = std.fmt.parseInt(usize, line[1..], 10) catch return error.InvalidProtocol;
        var command = Command.init(self.allocator);

        for (0..count) |_| {
            const bulk_line = try self.readLine(reader);
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

        var read_total: usize = 0;
        while (read_total < ulen) {
            const n = try reader.readSliceShort(data[read_total..]);
            if (n == 0) return error.EndOfStream;
            read_total += n;
        }

        // Expect trailing CRLF after the bulk string payload
        var crlf: [2]u8 = undefined;
        _ = try reader.readSliceShort(&crlf);
        if (crlf[0] != '\r' or crlf[1] != '\n') {
            return error.InvalidProtocol;
        }

        return data;
    }

    // Reads a RESP line terminated by CRLF. Returns slice of internal buffer (valid until next call).
    fn readLine(self: *Parser, reader: *std.Io.Reader) ![]const u8 {
        var i: usize = 0;
        while (true) {
            var b_buf: [1]u8 = undefined;
            const bytes_read = try reader.readSliceShort(&b_buf);
            if (bytes_read == 0) {
                if (i == 0) return error.EndOfStream;
                return error.InvalidProtocol;
            }
            const b = b_buf[0];
            switch (b) {
                '\r' => {
                    var next_buf: [1]u8 = undefined;
                    const next_bytes_read = reader.readSliceShort(&next_buf) catch |err| {
                        if (err == error.EndOfStream) return error.InvalidProtocol; // incomplete CRLF
                        return err;
                    };
                    if (next_bytes_read == 0) return error.InvalidProtocol;
                    if (next_buf[0] != '\n') return error.InvalidProtocol;
                    return self.line_buf[0..i];
                },
                else => {
                    if (i >= self.line_buf.len) return error.LineTooLong;
                    self.line_buf[i] = b;
                    i += 1;
                },
            }
        }
    }
};
