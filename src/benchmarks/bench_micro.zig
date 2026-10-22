const std = @import("std");
const banner = @import("../banner.zig");
const bench_store = @import("bench_store.zig");
const bench_commands = @import("bench_commands.zig");

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
    try stdout.writeAll(&banner.repeat(" ", 35));
    try stdout.writeAll("ZEDIS MICRO-BENCHMARKS");
    try stdout.writeAll(&banner.repeat(" ", 41));
    try stdout.writeAll("█\n");
    try stdout.writeAll("█");
    try stdout.writeAll(&banner.repeat(" ", 98));
    try stdout.writeAll("█\n");
    try stdout.writeAll(&banner.repeat("█", 100));
    try stdout.writeAll("\n\n");

    try stdout.writeAll("Running micro-benchmarks to test component-level performance...\n");
    try stdout.writeAll("These benchmarks do NOT require a running server.\n\n");

    // Run store benchmarks
    try bench_store.run_all_benchmarks(allocator);

    // Run command benchmarks
    try bench_commands.run_all_benchmarks(allocator);

    try stdout.writeAll("\n");
    try stdout.writeAll(&banner.repeat("█", 100));
    try stdout.writeAll("\n");
    try stdout.writeAll("Micro-benchmarks completed successfully!\n");
    try stdout.writeAll(&banner.repeat("█", 100));
    try stdout.writeAll("\n");
}
