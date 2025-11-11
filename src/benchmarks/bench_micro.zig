const std = @import("std");
const bench_store = @import("bench_store.zig");
const bench_commands = @import("bench_commands.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_writer = std.fs.File.stdout().writer(&.{});
    var stdout = stdout_writer.interface;

    try stdout.writeAll("\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n");
    try stdout.writeAll("█" ++ " " ** 98 ++ "█\n");
    try stdout.writeAll("█" ++ " " ** 35 ++ "ZEDIS MICRO-BENCHMARKS" ++ " " ** 41 ++ "█\n");
    try stdout.writeAll("█" ++ " " ** 98 ++ "█\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n\n");

    try stdout.writeAll("Running micro-benchmarks to test component-level performance...\n");
    try stdout.writeAll("These benchmarks do NOT require a running server.\n\n");

    // Run store benchmarks
    try bench_store.runAllBenchmarks(allocator);

    // Run command benchmarks
    try bench_commands.runAllBenchmarks(allocator);

    try stdout.writeAll("\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n");
    try stdout.writeAll("Micro-benchmarks completed successfully!\n");
    try stdout.writeAll("█" ** 100);
    try stdout.writeAll("\n");
}
