const std = @import("std");
const Store = @import("store.zig").Store;
const Value = @import("parser.zig").Value;
const PrimitiveValue = @import("store.zig").PrimitiveValue;

pub const MockClient = struct {
    client_id: u64,
    allocator: std.mem.Allocator,
    store: *Store,
    pubsub_context: *MockPubSubContext,
    output: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator, store: *Store, pubsub_context: *MockPubSubContext) MockClient {
        return MockClient{
            .client_id = 1,
            .allocator = allocator,
            .store = store,
            .pubsub_context = pubsub_context,
            .output = std.array_list.Managed(u8).init(allocator),
        };
    }

    // Legacy init for existing tests (without pubsub functionality)
    pub fn initLegacy(allocator: std.mem.Allocator, store: *Store) MockClient {
        // Create a dummy pubsub context for legacy tests
        var dummy_server = MockServer{
            .allocator = allocator,
            .channels = [_]?[]const u8{null} ** 8,
            .subscribers = [_][16]u64{[_]u64{0} ** 16} ** 8,
            .subscriber_counts = [_]u32{0} ** 8,
            .clients = std.array_list.Managed(*MockClient).init(allocator),
            .channel_count = 0,
        };

        var dummy_context = MockPubSubContext.init(&dummy_server);

        return MockClient{
            .client_id = 1,
            .allocator = allocator,
            .store = store,
            .pubsub_context = &dummy_context,
            .output = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn initWithId(client_id: u64, allocator: std.mem.Allocator, store: *Store, pubsub_context: *MockPubSubContext) MockClient {
        return MockClient{
            .client_id = client_id,
            .allocator = allocator,
            .store = store,
            .pubsub_context = pubsub_context,
            .output = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *MockClient) void {
        self.output.deinit();
    }

    pub fn writeBulkString(self: *MockClient, str: []const u8) !void {
        try self.output.writer().print("${d}\r\n{s}\r\n", .{ str.len, str });
    }

    pub fn writeNull(self: *MockClient) !void {
        try self.output.appendSlice("$-1\r\n");
    }

    pub fn writeError(self: *MockClient, comptime fmt: []const u8, args: anytype) !void {
        try self.output.appendSlice("-");
        try self.output.writer().print(fmt, args);
        try self.output.appendSlice("\r\n");
    }

    pub fn writeInt(self: *MockClient, num: anytype) !void {
        try self.output.writer().print(":{d}\r\n", .{num});
    }

    pub fn writePrimitiveValue(self: *MockClient, value: PrimitiveValue) !void {
        switch (value) {
            .string => |s| try self.writeBulkString(s),
            .int => |i| try self.writeIntAsString(i),
        }
    }

    pub fn getOutput(self: *MockClient) []const u8 {
        return self.output.items;
    }

    pub fn clearOutput(self: *MockClient) void {
        self.output.clearRetainingCapacity();
    }

    // Test-specific command implementations that don't need @ptrCast
    pub fn testSet(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const value = args[2].asSlice();

        const maybe_int = std.fmt.parseInt(i64, value, 10);

        if (maybe_int) |int_value| {
            try self.store.setInt(key, int_value);
        } else |_| {
            try self.store.set(key, value);
        }

        try self.output.appendSlice("+OK\r\n");
    }

    pub fn testGet(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const value = self.store.get(key);

        if (value) |v| {
            switch (v.value) {
                .string => |s| try self.writeBulkString(s),
                .short_string => |ss| try self.writeBulkString(ss.asSlice()),
                .int => |i| {
                    const int_str = try std.fmt.allocPrint(self.allocator, "{d}", .{i});
                    defer self.allocator.free(int_str);
                    try self.writeBulkString(int_str);
                },
                .list => try self.writeNull(), // Lists not supported in GET
            }
        } else {
            try self.writeNull();
        }
    }

    pub fn testIncr(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();

        // Simple INCR implementation for testing
        const current_value = self.store.get(key);
        var new_value: i64 = 1;

        if (current_value) |v| {
            switch (v.value) {
                .string => |s| {
                    new_value = std.fmt.parseInt(i64, s, 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value += 1;
                },
                .short_string => |ss| {
                    new_value = std.fmt.parseInt(i64, ss.asSlice(), 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value += 1;
                },
                .int => |i| {
                    new_value = i + 1;
                },
                .list => {
                    try self.writeError("ERR value is not an integer or out of range", .{});
                    return;
                },
            }
        }

        try self.store.setInt(key, new_value);
        const result_str = try std.fmt.allocPrint(self.allocator, "{d}", .{new_value});
        defer self.allocator.free(result_str);
        try self.writeBulkString(result_str);
    }

    pub fn testDecr(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();

        // Simple DECR implementation for testing
        const current_value = self.store.get(key);
        var new_value: i64 = -1;

        if (current_value) |v| {
            switch (v.value) {
                .string => |s| {
                    new_value = std.fmt.parseInt(i64, s, 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value -= 1;
                },
                .short_string => |ss| {
                    new_value = std.fmt.parseInt(i64, ss.asSlice(), 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value -= 1;
                },
                .int => |i| {
                    new_value = i - 1;
                },
                .list => {
                    try self.writeError("ERR value is not an integer or out of range", .{});
                    return;
                },
            }
        }

        try self.store.setInt(key, new_value);
        const result_str = try std.fmt.allocPrint(self.allocator, "{d}", .{new_value});
        defer self.allocator.free(result_str);
        try self.writeBulkString(result_str);
    }

    pub fn testDel(self: *MockClient, args: []const Value) !void {
        var deleted: u32 = 0;
        for (args[1..]) |key| {
            if (self.store.delete(key.asSlice())) {
                deleted += 1;
            }
        }

        try self.writeInt(deleted);
    }

    pub fn testAppend(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const append_value = args[2].asSlice();

        const current_value = self.store.get(key);
        var new_value: []const u8 = undefined;
        var needs_free = false;

        if (current_value) |v| {
            const current_str = switch (v.value) {
                .string => |s| s,
                .short_string => |ss| ss.asSlice(),
                .int => |i| blk: {
                    var buf: [21]u8 = undefined;
                    break :blk std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                },
                .list => {
                    try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
                    return;
                },
            };

            const concatenated = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ current_str, append_value });
            new_value = concatenated;
            needs_free = true;
        } else {
            new_value = append_value;
        }

        defer if (needs_free) self.allocator.free(new_value);
        try self.store.set(key, new_value);

        try self.writeInt(new_value.len);
    }

    pub fn testStrlen(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const value = self.store.get(key);

        if (value) |v| {
            const len: usize = switch (v.value) {
                .string => |s| s.len,
                .short_string => |ss| ss.len,
                .int => |i| blk: {
                    var buf: [21]u8 = undefined;
                    const str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                    break :blk str.len;
                },
                .list => {
                    try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
                    return;
                },
            };
            try self.writeInt(len);
        } else {
            try self.writeInt(0);
        }
    }

    pub fn testGetset(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const new_value = args[2].asSlice();

        const old_value = self.store.get(key);

        if (old_value) |v| {
            switch (v.value) {
                .string => |s| try self.writeBulkString(s),
                .short_string => |ss| try self.writeBulkString(ss.asSlice()),
                .int => |i| {
                    const int_str = try std.fmt.allocPrint(self.allocator, "{d}", .{i});
                    defer self.allocator.free(int_str);
                    try self.writeBulkString(int_str);
                },
                .list => {
                    try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
                    return;
                },
            }
        } else {
            try self.writeNull();
        }

        try self.store.set(key, new_value);
    }

    pub fn testMget(self: *MockClient, args: []const Value) !void {
        try self.writeListLen(args.len - 1);

        for (args[1..]) |key_arg| {
            const key = key_arg.asSlice();
            const value = self.store.get(key);

            if (value) |v| {
                switch (v.value) {
                    .string => |s| try self.writeBulkString(s),
                    .short_string => |ss| try self.writeBulkString(ss.asSlice()),
                    .int => |i| {
                        const int_str = try std.fmt.allocPrint(self.allocator, "{d}", .{i});
                        defer self.allocator.free(int_str);
                        try self.writeBulkString(int_str);
                    },
                    .list => try self.writeNull(),
                }
            } else {
                try self.writeNull();
            }
        }
    }

    pub fn testMset(self: *MockClient, args: []const Value) !void {
        if (args.len % 2 != 1) {
            try self.writeError("ERR wrong number of arguments for 'mset' command", .{});
            return;
        }

        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const key = args[i].asSlice();
            const value = args[i + 1].asSlice();
            try self.store.set(key, value);
        }

        try self.output.appendSlice("+OK\r\n");
    }

    pub fn testSetex(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const seconds = args[2].asInt() catch {
            try self.writeError("ERR value is not an integer or out of range", .{});
            return;
        };
        const value = args[3].asSlice();

        try self.store.set(key, value);

        if (seconds > 0) {
            const expiration_time = std.time.milliTimestamp() + (seconds * 1000);
            _ = try self.store.expire(key, expiration_time);
        }

        try self.output.appendSlice("+OK\r\n");
    }

    pub fn testSetnx(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const value = args[2].asSlice();

        const exists = self.store.get(key) != null;

        if (!exists) {
            try self.store.set(key, value);
            try self.writeInt(1);
        } else {
            try self.writeInt(0);
        }
    }

    pub fn testIncrby(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const increment = args[2].asInt() catch {
            try self.writeError("ERR value is not an integer or out of range", .{});
            return;
        };

        const current_value = self.store.get(key);
        var new_value: i64 = increment;

        if (current_value) |v| {
            switch (v.value) {
                .string => |s| {
                    const int_val = std.fmt.parseInt(i64, s, 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value = std.math.add(i64, int_val, increment) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                },
                .short_string => |ss| {
                    const int_val = std.fmt.parseInt(i64, ss.asSlice(), 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value = std.math.add(i64, int_val, increment) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                },
                .int => |i| {
                    new_value = std.math.add(i64, i, increment) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                },
                .list => {
                    try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
                    return;
                },
            }
        }

        try self.store.setInt(key, new_value);
        const result_str = try std.fmt.allocPrint(self.allocator, "{d}", .{new_value});
        defer self.allocator.free(result_str);
        try self.writeBulkString(result_str);
    }

    pub fn testDecrby(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const decrement = args[2].asInt() catch {
            try self.writeError("ERR value is not an integer or out of range", .{});
            return;
        };

        const current_value = self.store.get(key);
        var new_value: i64 = -decrement;

        if (current_value) |v| {
            switch (v.value) {
                .string => |s| {
                    const int_val = std.fmt.parseInt(i64, s, 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value = std.math.sub(i64, int_val, decrement) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                },
                .short_string => |ss| {
                    const int_val = std.fmt.parseInt(i64, ss.asSlice(), 10) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                    new_value = std.math.sub(i64, int_val, decrement) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                },
                .int => |i| {
                    new_value = std.math.sub(i64, i, decrement) catch {
                        try self.writeError("ERR value is not an integer or out of range", .{});
                        return;
                    };
                },
                .list => {
                    try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
                    return;
                },
            }
        }

        try self.store.setInt(key, new_value);
        const result_str = try std.fmt.allocPrint(self.allocator, "{d}", .{new_value});
        defer self.allocator.free(result_str);
        try self.writeBulkString(result_str);
    }

    pub fn testIncrbyfloat(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const increment_str = args[2].asSlice();

        const increment = std.fmt.parseFloat(f64, increment_str) catch {
            try self.writeError("ERR value is not a valid float", .{});
            return;
        };

        const current_value = self.store.get(key);
        var current_float: f64 = 0.0;

        if (current_value) |v| {
            switch (v.value) {
                .string => |s| {
                    current_float = std.fmt.parseFloat(f64, s) catch {
                        try self.writeError("ERR value is not a valid float", .{});
                        return;
                    };
                },
                .short_string => |ss| {
                    current_float = std.fmt.parseFloat(f64, ss.asSlice()) catch {
                        try self.writeError("ERR value is not a valid float", .{});
                        return;
                    };
                },
                .int => |i| {
                    current_float = @floatFromInt(i);
                },
                .list => {
                    try self.writeError("WRONGTYPE Operation against a key holding the wrong kind of value", .{});
                    return;
                },
            }
        }

        const new_float = current_float + increment;

        var buf: [64]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d:.17}", .{new_float}) catch {
            try self.writeError("ERR overflow", .{});
            return;
        };

        // Remove trailing zeros and trailing decimal point
        var end = formatted.len;
        if (std.mem.indexOf(u8, formatted, ".")) |_| {
            while (end > 0 and formatted[end - 1] == '0') {
                end -= 1;
            }
            if (end > 0 and formatted[end - 1] == '.') {
                end -= 1;
            }
        }

        const result = formatted[0..end];
        try self.store.set(key, result);
        try self.writeBulkString(result);
    }

    // List command test methods
    pub fn writeListLen(self: *MockClient, count: usize) !void {
        try self.output.writer().print("*{d}\r\n", .{count});
    }

    pub fn writeIntAsString(self: *MockClient, i: i64) !void {
        var buf: [21]u8 = undefined; // Enough for i64
        const int_str = try std.fmt.bufPrint(&buf, "{}", .{i});
        try self.writeBulkString(int_str);
    }

    pub fn testLpush(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const list = try self.store.getSetList(key);

        for (args[2..]) |arg| {
            try list.prepend(.{ .string = arg.asSlice() });
        }

        try self.writeInt(list.len());
    }

    pub fn testRpush(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const list = try self.store.getSetList(key);

        for (args[2..]) |arg| {
            try list.append(.{ .string = arg.asSlice() });
        }

        try self.writeInt(list.len());
    }

    pub fn testLpop(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const list = try self.store.getList(key) orelse {
            try self.writeNull();
            return;
        };

        var count: usize = 1;
        if (args.len == 3) {
            count = try args[2].asUsize();
        }

        const list_len = list.len();
        const actual_count = @min(count, list_len);

        if (actual_count == 0) {
            try self.writeNull();
            return;
        }

        if (actual_count == 1) {
            const item = list.popFirst().?;
            switch (item) {
                .string => |str| try self.writeBulkString(str),
                .int => |i| try self.writeIntAsString(i),
            }
            return;
        }

        if (actual_count > 1) {
            try self.writeListLen(actual_count);
            for (0..actual_count) |_| {
                const item = list.popFirst().?;
                switch (item) {
                    .string => |str| try self.writeBulkString(str),
                    .int => |i| try self.writeIntAsString(i),
                }
            }
            return;
        }
    }

    pub fn testRpop(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const list = try self.store.getList(key) orelse {
            try self.writeNull();
            return;
        };

        var count: usize = 1;
        if (args.len == 3) {
            count = try args[2].asUsize();
        }

        const list_len = list.len();
        const actual_count = @min(count, list_len);

        if (actual_count == 0) {
            try self.writeNull();
            return;
        }

        if (actual_count == 1) {
            const item = list.pop().?;
            switch (item) {
                .string => |str| try self.writeBulkString(str),
                .int => |i| try self.writeIntAsString(i),
            }
            return;
        }

        if (actual_count > 1) {
            try self.writeListLen(actual_count);
            for (0..actual_count) |_| {
                const item = list.pop().?;
                switch (item) {
                    .string => |str| try self.writeBulkString(str),
                    .int => |i| try self.writeIntAsString(i),
                }
            }
            return;
        }
    }

    pub fn testLlen(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const list = try self.store.getList(key);

        if (list) |l| {
            try self.writeInt(l.len());
        } else {
            try self.writeInt(0);
        }
    }

    pub fn testLindex(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const index = try args[2].asInt();
        const list = try self.store.getList(key) orelse {
            try self.writeNull();
            return;
        };

        const item = list.getByIndex(index) orelse {
            try self.writeNull();
            return;
        };

        try self.writePrimitiveValue(item);
    }

    pub fn testLset(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const index = try args[2].asInt();
        const value = args[3].asSlice();

        const list = try self.store.getList(key) orelse {
            try self.writeError("ERR no such key", .{});
            return;
        };

        list.setByIndex(index, .{ .string = value }) catch {
            try self.writeError("ERR no such key", .{});
            return;
        };

        try self.writeBulkString("OK");
    }

    pub fn testLrange(self: *MockClient, args: []const Value) !void {
        const key = args[1].asSlice();
        const start = try args[2].asInt();
        const stop = try args[3].asInt();

        const list = try self.store.getList(key) orelse {
            try self.writeListLen(0);
            return;
        };

        const list_len = list.len();
        if (list_len == 0) {
            try self.writeListLen(0);
            return;
        }

        // Convert negative indices to positive and clamp to valid range
        const actual_start: usize = if (start < 0) blk: {
            const neg_offset = @as(usize, @intCast(-start));
            if (neg_offset > list_len) {
                break :blk 0;
            }
            break :blk list_len - neg_offset;
        } else blk: {
            const pos_index = @as(usize, @intCast(start));
            if (pos_index >= list_len) {
                try self.writeListLen(0);
                return;
            }
            break :blk pos_index;
        };

        const actual_stop: usize = if (stop < 0) blk: {
            const neg_offset = @as(usize, @intCast(-stop));
            if (neg_offset > list_len) {
                break :blk 0;
            }
            break :blk list_len - neg_offset;
        } else blk: {
            const pos_index = @as(usize, @intCast(stop));
            if (pos_index >= list_len) {
                break :blk list_len - 1;
            }
            break :blk pos_index;
        };

        // Handle invalid range
        if (actual_start > actual_stop) {
            try self.writeListLen(0);
            return;
        }

        const count = actual_stop - actual_start + 1;
        try self.writeListLen(count);

        // Stream items directly
        var current = list.list.first;
        var i: usize = 0;
        while (current) |node| : (i += 1) {
            if (i >= actual_start and i <= actual_stop) {
                const list_node: *const @import("store.zig").ZedisListNode = @fieldParentPtr("node", node);
                try self.writePrimitiveValue(list_node.data);
            }
            if (i > actual_stop) break;
            current = node.next;
        }
    }

    pub fn writeTupleAsArray(self: *MockClient, items: anytype) !void {
        const fields = std.meta.fields(@TypeOf(items));
        try self.output.writer().print("*{d}\r\n", .{fields.len});

        inline for (fields) |field| {
            const value = @field(items, field.name);
            switch (@TypeOf(value)) {
                []const u8 => try self.writeBulkString(value),
                i64, u64, u32, i32 => try self.output.writer().print(":{d}\r\n", .{value}),
                else => {
                    // Handle string literals like *const [N:0]u8
                    const TypeInfo = @typeInfo(@TypeOf(value));
                    switch (TypeInfo) {
                        .pointer => |ptr_info| {
                            // Handle both *const [N:0]u8 and []const u8 types
                            const child_info = @typeInfo(ptr_info.child);
                            if (ptr_info.child == u8 or (child_info == .array and child_info.array.child == u8)) {
                                try self.writeBulkString(value);
                            } else {
                                @compileError("Unsupported tuple field type: " ++ @typeName(@TypeOf(value)));
                            }
                        },
                        else => @compileError("Unsupported tuple field type: " ++ @typeName(@TypeOf(value))),
                    }
                },
            }
        }
    }
};

// MockServer for testing PubSub functionality
pub const MockServer = struct {
    allocator: std.mem.Allocator,
    channels: [8]?[]const u8, // Channel names (reduced for tests)
    subscribers: [8][16]u64, // Subscriber lists per channel (reduced for tests)
    subscriber_counts: [8]u32, // Number of subscribers per channel
    clients: std.array_list.Managed(*MockClient), // List of connected clients
    channel_count: u32,

    pub fn init(allocator: std.mem.Allocator) MockServer {
        return MockServer{
            .allocator = allocator,
            .channels = [_]?[]const u8{null} ** 8,
            .subscribers = [_][16]u64{[_]u64{0} ** 16} ** 8,
            .subscriber_counts = [_]u32{0} ** 8,
            .clients = std.array_list.Managed(*MockClient).init(allocator),
            .channel_count = 0,
        };
    }

    pub fn deinit(self: *MockServer) void {
        // Free allocated channel names
        for (self.channels) |channel| {
            if (channel) |name| {
                self.allocator.free(name);
            }
        }
        self.clients.deinit();
    }

    pub fn addClient(self: *MockServer, client: *MockClient) !void {
        try self.clients.append(client);
    }

    pub fn findOrCreateChannel(self: *MockServer, channel_name: []const u8) ?u32 {
        // Check if channel already exists
        for (self.channels[0..self.channel_count], 0..) |existing_name, i| {
            if (existing_name) |name| {
                if (std.mem.eql(u8, name, channel_name)) {
                    return @intCast(i);
                }
            }
        }

        // Create new channel if we have space
        if (self.channel_count >= self.channels.len) {
            return null; // Maximum channels reached
        }

        const owned_name = self.allocator.dupe(u8, channel_name) catch return null;
        self.channels[self.channel_count] = owned_name;
        const channel_id = self.channel_count;
        self.channel_count += 1;
        return channel_id;
    }

    pub fn subscribeToChannel(self: *MockServer, channel_id: u32, client_id: u64) !void {
        if (channel_id >= self.channel_count) return error.InvalidChannel;

        const current_count = self.subscriber_counts[channel_id];
        if (current_count >= self.subscribers[channel_id].len) {
            return error.ChannelFull;
        }

        // Check if already subscribed
        for (self.subscribers[channel_id][0..current_count]) |existing_id| {
            if (existing_id == client_id) return; // Already subscribed
        }

        self.subscribers[channel_id][current_count] = client_id;
        self.subscriber_counts[channel_id] += 1;
    }

    pub fn unsubscribeFromChannel(self: *MockServer, channel_id: u32, client_id: u64) void {
        if (channel_id >= self.channel_count) return;

        const current_count = self.subscriber_counts[channel_id];
        var i: u32 = 0;
        while (i < current_count) : (i += 1) {
            if (self.subscribers[channel_id][i] == client_id) {
                // Move last subscriber to this position
                if (i < current_count - 1) {
                    self.subscribers[channel_id][i] = self.subscribers[channel_id][current_count - 1];
                }
                self.subscriber_counts[channel_id] -= 1;
                return;
            }
        }
    }

    pub fn getChannelSubscribers(self: *MockServer, channel_id: u32) []const u64 {
        if (channel_id >= self.channel_count) return &[_]u64{};
        return self.subscribers[channel_id][0..self.subscriber_counts[channel_id]];
    }

    pub fn getChannelNames(self: *MockServer) []const ?[]const u8 {
        return &self.channels;
    }

    pub fn getChannelCount(self: *MockServer) u32 {
        return self.channel_count;
    }

    pub fn findClientById(self: *MockServer, client_id: u64) ?*MockClient {
        for (self.clients.items) |client| {
            if (client.client_id == client_id) {
                return client;
            }
        }
        return null;
    }
};

// MockPubSubContext that wraps MockServer
pub const MockPubSubContext = struct {
    server: *MockServer,

    pub fn init(server: *MockServer) MockPubSubContext {
        return MockPubSubContext{ .server = server };
    }

    pub fn findOrCreateChannel(self: *MockPubSubContext, channel_name: []const u8) ?u32 {
        return self.server.findOrCreateChannel(channel_name);
    }

    pub fn subscribeToChannel(self: *MockPubSubContext, channel_id: u32, client_id: u64) !void {
        return self.server.subscribeToChannel(channel_id, client_id);
    }

    pub fn unsubscribeFromChannel(self: *MockPubSubContext, channel_id: u32, client_id: u64) void {
        self.server.unsubscribeFromChannel(channel_id, client_id);
    }

    pub fn getChannelSubscribers(self: *MockPubSubContext, channel_id: u32) []const u64 {
        return self.server.getChannelSubscribers(channel_id);
    }

    pub fn getChannelNames(self: *MockPubSubContext) []const ?[]const u8 {
        return self.server.getChannelNames();
    }

    pub fn getChannelCount(self: *MockPubSubContext) u32 {
        return self.server.getChannelCount();
    }

    pub fn findClientById(self: *MockPubSubContext, client_id: u64) ?*MockClient {
        return self.server.findClientById(client_id);
    }
};
