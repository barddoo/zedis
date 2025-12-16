const std = @import("std");
const testing = std.testing;
const Value = @import("../parser.zig").Value;
const connection = @import("connection.zig");
const Io = std.Io;
const Writer = Io.Writer;

test "CONFIG GET param returns empty array" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "GET" },
    .{ .data = "maxmemory" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG GET without param returns empty array" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "GET" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG with no subcommand returns empty array" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG case insensitive subcommand - lowercase get" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "get" },
    .{ .data = "maxmemory" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG case insensitive subcommand - mixed case" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "GeT" },
    .{ .data = "maxmemory" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG with invalid subcommand returns empty array" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "INVALID" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG with SET subcommand returns empty array" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "SET" },
    .{ .data = "maxmemory" },
    .{ .data = "1000000" },
  };

  try connection.config(&writer, &args);

  try testing.expectEqualStrings("*0\r\n", writer.buffered());
}

test "CONFIG RESP protocol byte sequence accuracy" {
  var buffer: [4096]u8 = undefined;
  var writer = Writer.fixed(&buffer);

  const args = [_]Value{
    .{ .data = "CONFIG" },
    .{ .data = "GET" },
    .{ .data = "save" },
  };

  try connection.config(&writer, &args);

  const output = writer.buffered();

  // Verify exact RESP format: array length 0
  try testing.expectEqual(@as(usize, 4), output.len);
  try testing.expectEqual(@as(u8, '*'), output[0]);
  try testing.expectEqual(@as(u8, '0'), output[1]);
  try testing.expectEqual(@as(u8, '\r'), output[2]);
  try testing.expectEqual(@as(u8, '\n'), output[3]);
}
