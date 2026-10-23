const std = @import("std");
const zio = @import("zio");
const Server = @import("app/server.zig");
const Config = @import("app/config.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Runtime tuning keys must be known before the runtime exists; read them
    // from the config file with blocking I/O (the async parse runs later).
    const runtime_prefs = Config.read_runtime_prefs(allocator, init.minimal.args);

    var rt_options: zio.RuntimeOptions = .{
        // Always a single executor. Command execution is serialized by design
        // and, with several executors, coroutines and the store bounce between
        // threads on every command: on an M4, .auto ran at ~1.2M rps pipelined
        // using ~4.5 cores, while one executor ran at 2.66M+ rps
        // (load-generator bound) on ~0.75 cores, and ~35% faster without
        // pipelining.
        .executors = .exact(1),
    };
    if (runtime_prefs.metrics_log_interval_seconds > 0) {
        rt_options.metrics_log_interval = zio.Duration.fromSeconds(runtime_prefs.metrics_log_interval_seconds);
    }
    rt_options.stack_pool.prewarm = runtime_prefs.stack_pool_prewarm;

    const rt = try zio.Runtime.init(allocator, rt_options);
    defer rt.deinit();
    const io = rt.io();

    const cfg = Config.read_config(allocator, io, init.minimal.args) catch |err| {
        switch (err) {
            error.UnknownMemoryLimit => {
                log.err("Cannot determine how much memory the server may use.", .{});
                log.err("Set maxmemory explicitly (e.g. maxmemory 2gb), or maxmemory 0 to disable the budget.", .{});
            },
            else => log.err("Failed to read config: {s}", .{@errorName(err)}),
        }
        return err;
    };

    if (cfg.memory_budget_source == .default) {
        log.warn("No container memory limit detected; using a {d} MB KV budget.", .{Config.host_kv_budget / (1024 * 1024)});
        log.warn("Set maxmemory to size it explicitly, or maxmemory 0 to disable the budget.", .{});
    }

    // Create and start the server with configuration
    const redis_server = Server.init_with_config(allocator, cfg.bind, cfg.port, cfg, io) catch |err| {
        log.err("Failed to initialize server: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.destroy(redis_server);
    defer redis_server.deinit();

    log.info("Zedis server listening on {s}:{d}", .{ cfg.bind, cfg.port });

    // Log config
    log.info("Configuration loaded:", .{});
    log.info("  Network: {s}:{d}", .{ cfg.bind, cfg.port });
    log.info("  AOF enabled: {}", .{cfg.appendonly});
    log.info("  Memory budget: {d} MB{s}", .{ cfg.total_memory_budget() / (1024 * 1024), if (cfg.memory_budget_source == .container) " (auto-sized)" else "" });
    log.info("  Max clients: {d}", .{cfg.max_clients});
    log.info("  Eviction policy: {s}", .{@tagName(cfg.eviction_policy)});
    if (cfg.requires_auth()) {
        log.info("  Auth: enabled", .{});
    } else {
        log.info("  Auth: disabled", .{});
    }

    redis_server.listen() catch |err| {
        log.err("Server error: {s}", .{@errorName(err)});
        return err;
    };
}

// Zig 0.17 only runs tests in files a test block references; list every file
// with tests so `zig build test` runs them.
test {
    _ = @import("persistence/aof.zig");
    _ = @import("benchmarks/bench_runner.zig");
    _ = @import("benchmarks/metrics.zig");
    _ = @import("storage/bloom/bloom_filter.zig");
    _ = @import("storage/bloom/scalable.zig");
    _ = @import("util/client_mailbox.zig");
    _ = @import("commands/bloom.zig");
    _ = @import("commands/connection.zig");
    _ = @import("commands/keys.zig");
    _ = @import("commands/list.zig");
    _ = @import("commands/registry.zig");
    _ = @import("commands/search.zig");
    _ = @import("commands/string.zig");
    _ = @import("util/compression/gorilla.zig");
    _ = @import("app/config.zig");
    _ = @import("storage/kv_allocator.zig");
    _ = @import("protocol/parser.zig");
    _ = @import("persistence/zdb.zig");
    _ = @import("storage/search/index.zig");
    _ = @import("storage/search/inverted.zig");
    _ = @import("storage/search/numeric.zig");
    _ = @import("storage/search/query.zig");
    _ = @import("storage/search/tag.zig");
    _ = @import("storage/search/tokenize.zig");
    _ = @import("storage/search/vector.zig");
    _ = @import("app/server.zig");
    _ = @import("storage/store.zig");
    _ = @import("storage/time_series.zig");
    _ = @import("util/string_match.zig");
}
