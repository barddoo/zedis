const std = @import("std");
const builtin = @import("builtin");
const time = std.time;

/// Test result tracking
pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    error_message: ?[]const u8,
    duration_ns: u64,
};

/// Test statistics
pub const TestStats = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    duration_ns: u64 = 0,

    pub fn success_rate(self: TestStats) f64 {
        if (self.total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(self.total));
    }
};

/// Test runner configuration
pub const TestConfig = struct {
    filter: ?[]const u8 = null,
    verbose: bool = false,
    quiet: bool = false,
    parallel: bool = false,
    timeout_ms: u32 = 30000, // 30 second default timeout
    max_threads: u32 = 0, // 0 = use CPU count
};

/// Enhanced test runner with filtering and reporting
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    config: TestConfig,
    results: std.array_list.Managed(TestResult),
    stats: TestStats,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: TestConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .results = std.array_list.Managed(TestResult).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.results.items) |result| {
            if (result.error_message) |msg| {
                self.allocator.free(msg);
            }
        }
        self.results.deinit();
    }

    /// Check if a test name matches the filter
    pub fn matchesFilter(self: *const Self, test_name: []const u8) bool {
        if (self.config.filter == null) return true;

        const filter = self.config.filter.?;
        return std.mem.indexOf(u8, test_name, filter) != null;
    }

    /// Run a single test function
    pub fn runTest(self: *Self, comptime test_name: []const u8, comptime test_func: fn () anyerror!void) !void {
        if (!self.matchesFilter(test_name)) return;

        const test_start = try time.Timer.start();

        if (!self.config.quiet) {
            if (self.config.verbose) {
                std.debug.print("Running test: {s}...\n", .{test_name});
            } else {
                std.debug.print(".", .{});
            }
        }

        var result = TestResult{
            .name = test_name,
            .passed = false,
            .error_message = null,
            .duration_ns = 0,
        };

        // Run the test with error handling
        test_func() catch |err| {
            result.passed = false;
            result.error_message = try std.fmt.allocPrint(self.allocator, "{}", .{err});
            self.stats.failed += 1;
        };

        if (result.error_message == null) {
            result.passed = true;
            self.stats.passed += 1;
        }

        result.duration_ns = test_start.read();
        self.stats.total += 1;
        self.stats.duration_ns += result.duration_ns;

        try self.results.append(result);
    }

    /// Print comprehensive test report
    pub fn printReport(self: *Self) void {
        const total_duration = @as(f64, @floatFromInt(self.stats.duration_ns)) / 1_000_000_000.0;

        if (!self.config.quiet) {
            std.debug.print("\n\n");
            std.debug.print("========================================\n");
            std.debug.print("           TEST RESULTS\n");
            std.debug.print("========================================\n");
            std.debug.print("Total:   {d}\n", .{self.stats.total});
            std.debug.print("Passed:  {d}\n", .{self.stats.passed});
            std.debug.print("Failed:  {d}\n", .{self.stats.failed});
            std.debug.print("Success: {d:.1}%\n", .{self.stats.success_rate() * 100.0});
            std.debug.print("Time:    {d:.3}s\n", .{total_duration});
            std.debug.print("========================================\n");
        }

        // Print detailed failure information
        if (self.stats.failed > 0) {
            std.debug.print("\nFAILED TESTS:\n");
            std.debug.print("----------------------------------------\n");

            for (self.results.items) |result| {
                if (!result.passed) {
                    const duration_ms = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0;
                    std.debug.print("✗ {s} ({d:.2}ms)\n", .{ result.name, duration_ms });
                    if (result.error_message) |msg| {
                        std.debug.print("  Error: {s}\n", .{msg});
                    }
                }
            }
            std.debug.print("----------------------------------------\n");
        }

        // Print verbose success information if requested
        if (self.config.verbose and self.stats.passed > 0) {
            std.debug.print("\nPASSED TESTS:\n");
            std.debug.print("----------------------------------------\n");

            for (self.results.items) |result| {
                if (result.passed) {
                    const duration_ms = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0;
                    std.debug.print("✓ {s} ({d:.2}ms)\n", .{ result.name, duration_ms });
                }
            }
            std.debug.print("----------------------------------------\n");
        }

        if (self.stats.failed == 0) {
            std.debug.print("\n🎉 All tests passed!\n");
        } else {
            std.debug.print("\n❌ {d} test(s) failed.\n", .{self.stats.failed});
        }
    }

    /// Get exit code based on test results
    pub fn getExitCode(self: *const Self) u8 {
        return if (self.stats.failed == 0) 0 else 1;
    }
};

/// Helper macro for running all tests in a module
pub fn runAllTests(
    allocator: std.mem.Allocator,
    config: TestConfig,
    comptime test_module: type,
) !u8 {
    var runner = TestRunner.init(allocator, config);
    defer runner.deinit();

    const module_info = @typeInfo(test_module);

    if (module_info != .Struct) {
        @compileError("Expected struct type for test module");
    }

    // Run all test functions in the module
    inline for (module_info.Struct.decls) |decl| {
        if (comptime std.mem.startsWith(u8, decl.name, "test")) {
            const test_func = @field(test_module, decl.name);
            const func_info = @typeInfo(@TypeOf(test_func));

            if (func_info == .Fn and func_info.Fn.params.len == 0) {
                try runner.runTest(decl.name, test_func);
            }
        }
    }

    runner.printReport();
    return runner.getExitCode();
}

/// Parse command line arguments into TestConfig
pub fn parseArgs(_: std.mem.Allocator, args: []const []const u8) !TestConfig {
    var config = TestConfig{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--filter") or std.mem.eql(u8, arg, "-f")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --filter requires a value\n", .{});
                return error.InvalidArgument;
            }
            i += 1;
            config.filter = args[i];
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            config.quiet = true;
        } else if (std.mem.eql(u8, arg, "--parallel") or std.mem.eql(u8, arg, "-p")) {
            config.parallel = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --timeout requires a value\n", .{});
                return error.InvalidArgument;
            }
            i += 1;
            config.timeout_ms = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid timeout value: {s}\n", .{args[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--max-threads")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --max-threads requires a value\n", .{});
                return error.InvalidArgument;
            }
            i += 1;
            config.max_threads = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Error: Invalid max-threads value: {s}\n", .{args[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return error.HelpRequested;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Treat non-flag arguments as filter patterns
            config.filter = arg;
        }
    }

    return config;
}

fn printHelp() void {
    std.debug.print(
        \\Zedis Test Runner
        \\
        \\USAGE:
        \\  zig build test [OPTIONS] [FILTER]
        \\
        \\OPTIONS:
        \\  -f, --filter PATTERN    Run only tests matching PATTERN
        \\  -v, --verbose           Show detailed output for all tests
        \\  -q, --quiet             Suppress progress output
        \\  -p, --parallel          Run tests in parallel (when supported)
        \\      --timeout MS        Set test timeout in milliseconds (default: 30000)
        \\      --max-threads N     Maximum number of threads for parallel execution
        \\  -h, --help              Show this help message
        \\
        \\EXAMPLES:
        \\  zig build test                    # Run all tests
        \\  zig build test -- string         # Run tests matching "string"
        \\  zig build test -- --verbose      # Run all tests with verbose output
        \\  zig build test -- --filter SET   # Run only SET-related tests
        \\
    , .{});
}

test "TestRunner basic functionality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = TestConfig{};
    var runner = TestRunner.init(allocator, config);
    defer runner.deinit();

    // Test the filter matching
    try std.testing.expect(runner.matchesFilter("test_something"));

    const config_with_filter = TestConfig{ .filter = "string" };
    var filtered_runner = TestRunner.init(allocator, config_with_filter);
    defer filtered_runner.deinit();

    try std.testing.expect(filtered_runner.matchesFilter("test_string_operations"));
    try std.testing.expect(!filtered_runner.matchesFilter("test_integer_operations"));
}

test "TestConfig argument parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test basic arguments
    const args1 = [_][]const u8{ "--verbose", "--filter", "test_string" };
    const config1 = try parseArgs(allocator, &args1);

    try std.testing.expect(config1.verbose);
    try std.testing.expectEqualStrings("test_string", config1.filter.?);

    // Test timeout parsing
    const args2 = [_][]const u8{ "--timeout", "5000" };
    const config2 = try parseArgs(allocator, &args2);

    try std.testing.expectEqual(@as(u32, 5000), config2.timeout_ms);
}
