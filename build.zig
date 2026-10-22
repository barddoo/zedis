const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .safe });

    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const zio_mod = zio.module("zio");

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "zedis",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zio", zio_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Passthru args are no longer visible at configure time in 0.17.
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // ZLS check
    const check_exe = b.addExecutable(.{ .name = "check", .root_module = exe.root_module });
    const check_step = b.step("check", "Check for build errors (ZLS)");
    check_step.dependOn(&check_exe.step);

    // --- Tests ---
    const test_filters = b.option([][]const u8, "test-filter", "Filter tests (e.g. -Dtest-filter=string)") orelse &[0][]const u8{};

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .debug,
    });
    test_mod.addImport("zio", zio_mod);

    const unit_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = test_mod,
        .filters = test_filters,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const test_build_step = b.step("test:build", "Build tests without running");
    test_build_step.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

    const fmt_step = b.step("test:fmt", "Check code formatting");
    const run_fmt = b.addFmt(.{ .paths = b.pathList(&.{"src"}), .check = true });
    fmt_step.dependOn(&run_fmt.step);

    const test_all_step = b.step("test:all", "Run tests and formatting checks");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(fmt_step);

    // --- Benchmarks ---
    const bench_micro_exe = b.addExecutable(.{
        .name = "bench-micro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_micro.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });
    bench_micro_exe.root_module.addImport("zio", zio_mod);

    const run_bench_micro = b.addRunArtifact(bench_micro_exe);
    const bench_micro_step = b.step("bench:micro", "Run micro-benchmarks");
    bench_micro_step.dependOn(&run_bench_micro.step);

    const bench_inline_exe = b.addExecutable(.{
        .name = "bench-inline",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_inline.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });
    bench_inline_exe.root_module.addImport("zio", zio_mod);

    const run_bench_inline = b.addRunArtifact(bench_inline_exe);
    const bench_inline_step = b.step("bench:inline", "Measure inline command execution (no store thread)");
    bench_inline_step.dependOn(&run_bench_inline.step);

    const bench_load_exe = b.addExecutable(.{
        .name = "benchmark-load",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_load.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });
    bench_load_exe.root_module.addImport("zio", zio_mod);

    const run_bench_load = b.addRunArtifact(bench_load_exe);
    const bench_load_step = b.step("bench:load", "Run load tests (requires running server)");
    bench_load_step.dependOn(&run_bench_load.step);

    const bench_all_step = b.step("bench", "Run micro-benchmarks");
    bench_all_step.dependOn(&run_bench_micro.step);
}
