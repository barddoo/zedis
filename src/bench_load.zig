const std = @import("std");
const zio = @import("zio");
const bench_load = @import("benchmarks/bench_load.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n");
    try stdout.writeAll("█" ++ " " ** 98 ++ "█\n");
    try stdout.writeAll("█" ++ " " ** 32 ++ "ZEDIS INTEGRATION LOAD TESTS" ++ " " ** 38 ++ "█\n");
    try stdout.writeAll("█" ++ " " ** 98 ++ "█\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n\n");

    try bench_load.runAllLoadTests(allocator, io);
}
