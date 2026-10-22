const std = @import("std");
const banner = @import("../banner.zig");
const bench_load = @import("bench_load.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_writer = std.Io.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\n");
    try stdout.writeAll(&banner.repeat("█", 100));
    try stdout.writeAll("\n");
    try stdout.writeAll("█");
    try stdout.writeAll(&banner.repeat(" ", 98));
    try stdout.writeAll("█\n");
    try stdout.writeAll("█");
    try stdout.writeAll(&banner.repeat(" ", 32));
    try stdout.writeAll("ZEDIS INTEGRATION LOAD TESTS");
    try stdout.writeAll(&banner.repeat(" ", 38));
    try stdout.writeAll("█\n");
    try stdout.writeAll("█");
    try stdout.writeAll(&banner.repeat(" ", 98));
    try stdout.writeAll("█\n");
    try stdout.writeAll(&banner.repeat("█", 100));
    try stdout.writeAll("\n\n");

    try bench_load.run_all_load_tests(allocator);
}
