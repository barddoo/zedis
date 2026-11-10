const std = @import("std");
const storeModule = @import("../storage/store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../app/client.zig").Client;
const Value = @import("parser.zig").Value;
const ZedisValue = storeModule.ZedisValue;
const PrimitiveValue = @import("../util/types.zig").PrimitiveValue;
const Io = std.Io;
const Writer = Io.Writer;

/// Protocol version the reply being written must use (2 or 3). The registry
/// sets it from the client before every command. Thread-local because commands
/// also run off the executor (the AOF rewrite thread replays the log); on one
/// thread nothing can interleave between that assignment and the writes, as
/// handlers never suspend.
pub threadlocal var version: u8 = 2;

// --- RESP Writing Helpers ---

/// Writes `msg` as a RESP error. `msg` must start with its error code
/// (e.g. "ERR ...", "WRONGTYPE ...", "NOAUTH ...").
pub fn write_error(writer: *Writer, msg: []const u8) !void {
    try writer.print("-{s}\r\n", .{msg});
}

pub fn write_simple_string(writer: *Writer, str: []const u8) !void {
    try writer.print("+{s}\r\n", .{str});
}

pub fn write_ok(writer: *Writer) !void {
    try writer.writeAll("+OK\r\n");
}

pub fn write_bulk_string(writer: *Writer, str: []const u8) !void {
    try writer.print("${d}\r\n{s}\r\n", .{ str.len, str });
}

pub fn write_int_bulk_string(writer: *Writer, value: i64) !void {
    // 20 bytes fits minInt(i64) with its sign.
    var buf: [20]u8 = undefined;
    const len = std.fmt.printInt(&buf, value, 10, .upper, .{});
    try writer.print("${d}\r\n{s}\r\n", .{ len, buf[0..len] });
}

pub fn write_single_int_bulk_string(writer: *Writer, value: i64) !void {
    try writer.print("${d}\r\n{d}\r\n", .{ 1, value });
}

pub fn write_int(writer: *Writer, value: anytype) !void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    // Compile-time check that value is an integer type
    comptime {
        if (type_info != .int and type_info != .comptime_int) {
            @compileError("write_int requires an integer type, got " ++ @typeName(T));
        }
    }

    try writer.print(":{d}\r\n", .{value});
}

pub fn write_list_len(writer: *Writer, count: usize) !void {
    try writer.print("*{d}\r\n", .{count});
}

pub fn write_tuple_as_array(writer: *Writer, items: anytype) !void {
    try write_tuple(writer, '*', items);
}

/// Out-of-band frame: a RESP3 push, or a plain array under RESP2.
pub fn write_push_len(writer: *Writer, count: usize) !void {
    const prefix: u8 = if (version >= 3) '>' else '*';
    try writer.print("{c}{d}\r\n", .{ prefix, count });
}

/// Like `write_tuple_as_array`, but framed as a push under RESP3.
pub fn write_push_tuple(writer: *Writer, items: anytype) !void {
    try write_tuple(writer, if (version >= 3) '>' else '*', items);
}

/// Writes a pre-serialized RESP2 array frame as a push when `protocol` is 3.
/// Takes the version explicitly because it runs outside command execution,
/// where `version` holds whatever the last command left behind.
pub fn write_frame_for_protocol(writer: *Writer, frame: []const u8, protocol: u8) !void {
    if (protocol >= 3 and frame.len > 0 and frame[0] == '*') {
        try writer.writeByte('>');
        try writer.writeAll(frame[1..]);
    } else {
        try writer.writeAll(frame);
    }
}

fn write_tuple(writer: *Writer, prefix: u8, items: anytype) !void {
    const T = @TypeOf(items);
    const info = @typeInfo(T);

    // 2. At compile time, verify the input is a tuple.
    //    A tuple in Zig is an anonymous struct.
    comptime {
        switch (info) {
            .@"struct" => |struct_info| {
                if (!struct_info.is_tuple) {
                    @compileError("This function only accepts a tuple. Received: " ++ @typeName(T));
                }
            },
            else => @compileError("This function only accepts a tuple. Received: " ++ @typeName(T)),
        }
    }

    const struct_info = info.@"struct";

    try writer.print("{c}{d}\r\n", .{ prefix, struct_info.field_names.len });

    // 4. Use 'inline for' to iterate over the tuple's elements at compile time.
    //    This loop is "unrolled" by the compiler, generating specific code
    //    for each element's type with no runtime overhead.
    inline for (items) |item| {
        // Check the type of the current item and call the correct serializer.
        const ItemType = @TypeOf(item);
        if (ItemType == []const u8) {
            try write_bulk_string(writer, item);
        } else if (ItemType == i64) {
            try write_int(writer, item);
        } else {
            // Handle string literals and other pointer-to-array types by checking if they can be coerced to []const u8
            const item_as_slice: []const u8 = item;
            try write_bulk_string(writer, item_as_slice);
        }
    }
}

/// Header for `pairs` key/value pairs: a RESP3 map, or a flat array of twice
/// as many elements under RESP2. The caller then writes key, value, key, ...
pub fn write_map_len(writer: *Writer, pairs: usize) !void {
    if (version >= 3) {
        try writer.print("%{d}\r\n", .{pairs});
    } else {
        try writer.print("*{d}\r\n", .{pairs * 2});
    }
}

/// Header for a set of `count` unique members: RESP3 set, or an array under RESP2.
pub fn write_set_len(writer: *Writer, count: usize) !void {
    const prefix: u8 = if (version >= 3) '~' else '*';
    try writer.print("{c}{d}\r\n", .{ prefix, count });
}

pub fn write_null(writer: *Writer) !void {
    try writer.writeAll(if (version >= 3) "_\r\n" else "$-1\r\n");
}

/// A RESP3 double, or its text in a bulk string under RESP2.
pub fn write_double_bulk_string(writer: *Writer, value: f64) !void {
    // Formatted straight into the reply: `{d}` prints every digit, so a value
    // like 1e300 runs to 301 characters and fits no fixed buffer.
    if (version >= 3) {
        try writer.print(",{d}\r\n", .{value});
    } else {
        try writer.print("${d}\r\n{d}\r\n", .{ std.fmt.count("{d}", .{value}), value });
    }
}

pub fn write_primitive_value(writer: *Writer, value: PrimitiveValue) !void {
    switch (value) {
        .string => |str| try write_bulk_string(writer, str),
        .short_string => |ss| try write_bulk_string(writer, ss.as_slice()),
        .int => |i| try write_int(writer, i),
    }
}

const RespCase = struct { version: u8, expected: []const u8 };

fn expect_reply(comptime write: anytype, args: anytype, cases: []const RespCase) !void {
    const saved = version;
    defer version = saved;
    for (cases) |case| {
        version = case.version;
        var buffer: [64]u8 = undefined;
        var writer: Writer = .fixed(&buffer);
        try @call(.auto, write, .{&writer} ++ args);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "null reply uses the protocol's null type" {
    try expect_reply(write_null, .{}, &.{
        .{ .version = 2, .expected = "$-1\r\n" },
        .{ .version = 3, .expected = "_\r\n" },
    });
}

test "double reply is a RESP3 double or a RESP2 bulk string" {
    try expect_reply(write_double_bulk_string, .{@as(f64, 1.5)}, &.{
        .{ .version = 2, .expected = "$3\r\n1.5\r\n" },
        .{ .version = 3, .expected = ",1.5\r\n" },
    });
    try expect_reply(write_double_bulk_string, .{std.math.inf(f64)}, &.{
        .{ .version = 3, .expected = ",inf\r\n" },
    });
}

test "double reply has no length limit on its digits" {
    const saved = version;
    defer version = saved;
    var digits: [301]u8 = undefined;
    @memset(&digits, '0');
    digits[0] = '1';

    var expected_buf: [320]u8 = undefined;
    var buffer: [320]u8 = undefined;
    for ([_]u8{ 2, 3 }) |protocol| {
        version = protocol;
        const expected = if (protocol == 2)
            try std.fmt.bufPrint(&expected_buf, "${d}\r\n{s}\r\n", .{ digits.len, digits })
        else
            try std.fmt.bufPrint(&expected_buf, ",{s}\r\n", .{digits});
        var writer: Writer = .fixed(&buffer);
        try write_double_bulk_string(&writer, 1e300);
        try std.testing.expectEqualStrings(expected, writer.buffered());
    }
}

test "map header is a RESP3 map or a flattened RESP2 array" {
    try expect_reply(write_map_len, .{@as(usize, 3)}, &.{
        .{ .version = 2, .expected = "*6\r\n" },
        .{ .version = 3, .expected = "%3\r\n" },
    });
}

test "set header is a RESP3 set or a RESP2 array" {
    try expect_reply(write_set_len, .{@as(usize, 2)}, &.{
        .{ .version = 2, .expected = "*2\r\n" },
        .{ .version = 3, .expected = "~2\r\n" },
    });
}

test "pub/sub frames are delivered as pushes only to RESP3 clients" {
    const frame = "*3\r\n$7\r\nmessage\r\n$1\r\nc\r\n$1\r\nm\r\n";
    var buffer: [64]u8 = undefined;

    var writer: Writer = .fixed(&buffer);
    try write_frame_for_protocol(&writer, frame, 2);
    try std.testing.expectEqualStrings(frame, writer.buffered());

    writer = .fixed(&buffer);
    try write_frame_for_protocol(&writer, frame, 3);
    try std.testing.expectEqualStrings(">" ++ frame[1..], writer.buffered());
}
