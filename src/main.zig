const std = @import("std");
const zio = @import("zio");
const Server = @import("server.zig");
const Config = @import("config.zig");

const log = std.log.scoped(.main);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Runtime tuning keys must be known before the runtime exists; read them
    // from the config file with blocking I/O (the async parse runs later).
    const runtime_prefs = Config.read_runtime_prefs(allocator, init.minimal.args);

    var rt_options: zio.RuntimeOptions = .{
        // One executor by default. Command execution is serialized by the
        // store lock (server.zig) anyway, and with several executors the lock
        // and coroutines bounce between threads on every command: on an M4,
        // .auto ran at ~1.2M rps pipelined using ~4.5 cores, while one
        // executor ran at 2.66M+ rps (load-generator bound) on ~0.75 cores,
        // and ~35% faster without pipelining. Set `executors` in the config
        // file (a count or "auto") to run more.
        .executors = if (runtime_prefs.executors == 0) .auto else .exact(runtime_prefs.executors),
    };
    if (runtime_prefs.metrics_log_interval_seconds > 0) {
        rt_options.metrics_log_interval = zio.Duration.fromSeconds(runtime_prefs.metrics_log_interval_seconds);
    }
    rt_options.stack_pool.prewarm = runtime_prefs.stack_pool_prewarm;

    const rt = try zio.Runtime.init(allocator, rt_options);
    defer rt.deinit();
    const io = rt.io();

    const cfg = Config.read_config(allocator, io, init.minimal.args) catch |err| {
        log.err("Failed to read config: {s}", .{@errorName(err)});
        return err;
    };

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
    log.info("  Memory budget: {d} MB", .{cfg.total_memory_budget() / (1024 * 1024)});
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
