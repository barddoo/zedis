const std = @import("std");
const bench_load = @import("benchmarks/bench_load.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n");
    try stdout.writeAll("█" ++ " " ** 98 ++ "█\n");
    try stdout.writeAll("█" ++ " " ** 32 ++ "ZEDIS INTEGRATION LOAD TESTS" ++ " " ** 38 ++ "█\n");
    try stdout.writeAll("█" ++ " " ** 98 ++ "█\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n\n");

    try bench_load.runAllLoadTests(allocator);
}
