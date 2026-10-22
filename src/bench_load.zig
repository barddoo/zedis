const std = @import("std");
const zio = @import("zio");
const banner = @import("banner.zig");
const bench_load = @import("benchmarks/bench_load.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const rt = try zio.Runtime.init(allocator, .{});
    defer rt.deinit();
    const io = rt.io();

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    try stdout.print("\n", .{});
    try stdout.print("{s}\n", .{&banner.repeat("█", 100)});
    try stdout.print("█{s}█\n", .{&banner.repeat(" ", 98)});
    try stdout.print("█{s}ZEDIS INTEGRATION LOAD TESTS{s}█\n", .{ &banner.repeat(" ", 32), &banner.repeat(" ", 38) });
    try stdout.print("█{s}█\n", .{&banner.repeat(" ", 98)});
    try stdout.print("{s}\n\n", .{&banner.repeat("█", 100)});

    try bench_load.run_all_load_tests(allocator, io);
}
