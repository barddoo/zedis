const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .fast });

    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const zio_mod = zio.module("zio");

    const ztls = b.dependency("ztls", .{ .target = target, .optimize = optimize });
    const ztls_mod = ztls.module("ztls");

    const lua_build = luaJITBuildStep(b, target);

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
    exe.root_module.addImport("ztls", ztls_mod);
    addLuaSources(b, exe.root_module, target);
    exe.step.dependOn(lua_build);
    // LuaJIT's GC needs a low 4 GB address space on x86_64 macOS. On arm64 the
    // override yields a malformed Mach-O (overlapping segments, SIGKILL at launch).
    if (target.result.os.tag == .macos and target.result.cpu.arch == .x86_64) {
        exe.pagezero_size = 0x10000;
        exe.image_base = 0x100000000;
    }
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
    test_mod.addImport("ztls", ztls_mod);
    addLuaSources(b, test_mod, target);

    const unit_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = test_mod,
        .filters = test_filters,
    });

    unit_tests.step.dependOn(lua_build);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    // Tests touch the filesystem and the clock, so a cached result can hide a
    // later regression (or replay a failure whose cause is already gone).
    // Inherited stdio also keeps the build runner from mistaking the tests'
    // expected log output for a failed command.
    run_unit_tests.stdio = .inherit;

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

fn luaJITBuildStep(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    const make = b.addSystemCommand(&.{"make"});
    make.addArg("-C");
    make.addDirectoryArg(b.path("vendor/luajit"));
    make.addArg("BUILDMODE=static");
    if (target.result.os.tag == .macos) {
        make.addArg("MACOSX_DEPLOYMENT_TARGET=13.0");
    }
    make.addArg("amalg");
    return &make.step;
}

fn addLuaSources(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    _ = b;
    module.link_libc = true;
    module.addSystemIncludePath(.{ .cwd_relative = "vendor/luajit/src" });
    module.addObjectFile(.{ .cwd_relative = "vendor/luajit/src/libluajit.a" });
    // LuaJIT on Linux pulls in pthread, math, and dynamic linker symbols.
    if (target.result.os.tag == .linux) {
        module.linkSystemLibrary("pthread", .{});
        module.linkSystemLibrary("m", .{});
        module.linkSystemLibrary("dl", .{});
    }
}
