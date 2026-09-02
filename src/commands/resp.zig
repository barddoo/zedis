const std = @import("std");
const storeModule = @import("../store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const Client = @import("../client.zig").Client;
const Value = @import("../parser.zig").Value;
const ZedisValue = storeModule.ZedisValue;
const PrimitiveValue = @import("../types.zig").PrimitiveValue;
const Io = std.Io;
const Writer = Io.Writer;

// --- RESP Writing Helpers ---

pub fn write_error(writer: *Writer, msg: []const u8) !void {
    try writer.print("-ERR {s}\r\n", .{msg});
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
    var buf: [19]u8 = undefined;
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

    try writer.print("*{d}\r\n", .{struct_info.fields.len});

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

pub fn write_null(writer: *Writer) !void {
    try writer.writeAll("$-1\r\n");
}

pub fn write_double_bulk_string(writer: *Writer, value: f64) !void {
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    try writer.print("${d}\r\n{s}\r\n", .{ formatted.len, formatted });
}

pub fn write_primitive_value(writer: *Writer, value: PrimitiveValue) !void {
    switch (value) {
        .string => |str| try write_bulk_string(writer, str),
        .short_string => |ss| try write_bulk_string(writer, ss.as_slice()),
        .int => |i| try write_int(writer, i),
    }
}
