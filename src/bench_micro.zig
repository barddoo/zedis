const std = @import("std");
const bench_store = @import("benchmarks/bench_store.zig");
const bench_commands = @import("benchmarks/bench_commands.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("                            ZEDIS MICRO-BENCHMARKS\n", .{});
    std.debug.print("=" ** 100 ++ "\n\n", .{});

    std.debug.print("Running micro-benchmarks to test component-level performance...\n", .{});
    std.debug.print("These benchmarks do NOT require a running server.\n\n", .{});

    // Run store benchmarks
    try bench_store.runAllBenchmarks(allocator);

    // Run command benchmarks
    try bench_commands.runAllBenchmarks(allocator);

    std.debug.print("\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
    std.debug.print("Micro-benchmarks completed successfully!\n", .{});
    std.debug.print("=" ** 100 ++ "\n", .{});
}
