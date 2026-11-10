const std = @import("std");
const builtin = @import("builtin");
const storeModule = @import("../storage/store.zig");
const Store = storeModule.Store;
const ZedisObject = storeModule.ZedisObject;
const client_module = @import("../app/client.zig");
const Client = client_module.Client;
const Value = @import("../protocol/parser.zig").Value;
const resp = @import("../protocol/resp.zig");
const Config = @import("../app/config.zig");
const Stats = @import("../app/stats.zig");
const Server = @import("../app/server.zig");
const CommandRegistry = @import("registry.zig").CommandRegistry;
const CommandInfo = @import("registry.zig").CommandInfo;
const server_version = Server.server_version;

pub fn flush_all(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    client.get_current_store().flush_db();
    try resp.write_ok(writer);
}

pub fn flush_db(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    client.get_current_store().flush_db();
    try resp.write_ok(writer);
}

pub fn db_size(writer: *std.Io.Writer, store: *Store, _: []const Value) !void {
    try resp.write_int(writer, store.size());
}

// --- Transactions ---

pub fn multi(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    if (client.transaction != null) {
        return resp.write_error(writer, "ERR MULTI calls can not be nested");
    }
    try client.beginTransaction();
    try resp.write_ok(writer);
}

pub fn discard(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    if (client.transaction == null) {
        return resp.write_error(writer, "ERR DISCARD without MULTI");
    }
    client.freeTransaction();
    try resp.write_ok(writer);
}

pub fn exec(client: *Client, _: []const Value, writer: *std.Io.Writer) !void {
    const transaction = client.transaction orelse {
        return resp.write_error(writer, "ERR EXEC without MULTI");
    };

    // Detach first so commands executed below do not get queued again.
    client.transaction = null;
    defer {
        transaction.deinit(client.allocator);
        client.allocator.destroy(transaction);
    }

    if (transaction.dirty) {
        return resp.write_error(writer, "EXECABORT Transaction discarded because of previous errors.");
    }

    try resp.write_list_len(writer, transaction.commands.items.len);
    for (transaction.commands.items) |command| {
        // Each queued command keeps its own memory gate and AOF logging, but
        // runs inline: the transaction is atomic with respect to other clients.
        client.server.execute_command(client, command.args, writer);
    }
}

// --- INFO ---

pub fn info_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const section = if (args.len > 1) args[1].as_slice() else "default";

    var buffer: std.Io.Writer.Allocating = .init(client.allocator);
    defer buffer.deinit();

    try writeInfo(client.server, &buffer.writer, section);
    const text = try buffer.toOwnedSlice();
    defer client.allocator.free(text);
    try resp.write_bulk_string(writer, text);
}

// --- METRICS (Prometheus text exposition) ---

pub fn metrics_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    _ = args;

    var buffer: std.Io.Writer.Allocating = .init(client.allocator);
    defer buffer.deinit();

    try writeMetrics(client.server, &buffer.writer);
    const text = try buffer.toOwnedSlice();
    defer client.allocator.free(text);
    try resp.write_bulk_string(writer, text);
}

fn writeMetrics(server: *Server, writer: *std.Io.Writer) !void {
    const memory = server.get_memory_stats();
    const counters = server.store.counters;
    const aof_fsync = server.aof_writer.lastFsyncInfo();

    server.stats.updateOps(server.io);

    const uptime = @max(@divTrunc(server.clock.now().toMilliseconds() - server.createdTime, 1000), 0);
    const hit_total = counters.keyspace_hits + counters.keyspace_misses;
    const hit_ratio: f64 = if (hit_total == 0)
        0.0
    else
        @as(f64, @floatFromInt(counters.keyspace_hits)) / @as(f64, @floatFromInt(hit_total));

    try writer.print(
        "# HELP zedis_up Whether the server is reachable.\n" ++
            "# TYPE zedis_up gauge\n" ++
            "zedis_up 1\n" ++
            "# TYPE zedis_uptime_seconds gauge\n" ++
            "zedis_uptime_seconds {d}\n" ++
            "# TYPE zedis_connected_clients gauge\n" ++
            "zedis_connected_clients {d}\n" ++
            "# TYPE zedis_maxclients gauge\n" ++
            "zedis_maxclients {d}\n" ++
            "# TYPE zedis_commands_processed_total counter\n" ++
            "zedis_commands_processed_total {d}\n" ++
            "# TYPE zedis_commands_failed_total counter\n" ++
            "zedis_commands_failed_total {d}\n" ++
            "# TYPE zedis_ops_per_second gauge\n" ++
            "zedis_ops_per_second {d}\n" ++
            "# TYPE zedis_net_input_bytes_total counter\n" ++
            "zedis_net_input_bytes_total {d}\n" ++
            "# TYPE zedis_net_output_bytes_total counter\n" ++
            "zedis_net_output_bytes_total {d}\n" ++
            "# TYPE zedis_keyspace_hits_total counter\n" ++
            "zedis_keyspace_hits_total {d}\n" ++
            "# TYPE zedis_keyspace_misses_total counter\n" ++
            "zedis_keyspace_misses_total {d}\n" ++
            "# TYPE zedis_keyspace_hit_ratio gauge\n" ++
            "zedis_keyspace_hit_ratio {d:.6}\n" ++
            "# TYPE zedis_expired_keys_total counter\n" ++
            "zedis_expired_keys_total {d}\n" ++
            "# TYPE zedis_evicted_keys_total counter\n" ++
            "zedis_evicted_keys_total {d}\n" ++
            "# TYPE zedis_keys gauge\n" ++
            "zedis_keys {d}\n" ++
            "# TYPE zedis_used_memory_bytes gauge\n" ++
            "zedis_used_memory_bytes {d}\n" ++
            "# TYPE zedis_used_memory_peak_bytes gauge\n" ++
            "zedis_used_memory_peak_bytes {d}\n" ++
            "# TYPE zedis_used_memory_dataset_bytes gauge\n" ++
            "zedis_used_memory_dataset_bytes {d}\n" ++
            "# TYPE zedis_maxmemory_bytes gauge\n" ++
            "zedis_maxmemory_bytes {d}\n" ++
            "# TYPE zedis_aof_enabled gauge\n" ++
            "zedis_aof_enabled {d}\n" ++
            "# TYPE zedis_aof_current_size_bytes gauge\n" ++
            "zedis_aof_current_size_bytes {d}\n" ++
            "# TYPE zedis_aof_pending_bytes gauge\n" ++
            "zedis_aof_pending_bytes {d}\n" ++
            "# TYPE zedis_aof_last_write_ok gauge\n" ++
            "zedis_aof_last_write_ok {d}\n" ++
            "# TYPE zedis_aof_fsync_count_total counter\n" ++
            "zedis_aof_fsync_count_total {d}\n" ++
            "# TYPE zedis_aof_last_fsync_duration_us gauge\n" ++
            "zedis_aof_last_fsync_duration_us {d}\n" ++
            "# TYPE zedis_aof_rewrites_total counter\n" ++
            "zedis_aof_rewrites_total {d}\n" ++
            "# TYPE zedis_slowlog_entries gauge\n" ++
            "zedis_slowlog_entries {d}\n",
        .{
            uptime,
            connectedClientCount(server),
            server.config.max_clients,
            server.stats.commands_processed,
            server.stats.commands_failed,
            server.stats.instantaneous_ops_per_sec,
            server.stats.total_net_input_bytes,
            server.stats.total_net_output_bytes,
            counters.keyspace_hits,
            counters.keyspace_misses,
            hit_ratio,
            counters.expired_keys,
            counters.evicted_keys,
            server.store.size(),
            memory.total_allocated,
            memory.fixed_memory_used + server.kv_allocator.get_peak_usage(),
            memory.kv_memory_used,
            server.config.kv_memory_budget,
            @intFromBool(server.aof_writer.enabled),
            server.aof_writer.currentSize(),
            server.aof_writer.pendingBytes(),
            @intFromBool(server.aof_writer.failure() == null),
            aof_fsync.count,
            aof_fsync.duration_us,
            server.aof_writer.rewriteInfo().count,
            server.slowlog.lenCount(),
        },
    );

    try writer.print(
        "# TYPE zedis_command_calls_total counter\n" ++
            "# TYPE zedis_command_usec_total counter\n",
        .{},
    );
    var iterator = server.stats.per_command.iterator();
    while (iterator.next()) |entry| {
        try writer.print(
            "zedis_command_calls_total{{command=\"{s}\"}} {d}\n" ++
                "zedis_command_usec_total{{command=\"{s}\"}} {d}\n",
            .{ entry.key_ptr.*, entry.value_ptr.calls, entry.key_ptr.*, entry.value_ptr.usec },
        );
    }
}

fn infoSectionSelected(filter: []const u8, section: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(filter, "all") or std.ascii.eqlIgnoreCase(filter, "everything")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(filter, "default")) {
        // Like Redis, the expensive per-command sections are opt-in.
        return !std.ascii.eqlIgnoreCase(section, "commandstats") and
            !std.ascii.eqlIgnoreCase(section, "latencystats") and
            !std.ascii.eqlIgnoreCase(section, "errorstats");
    }
    return std.ascii.eqlIgnoreCase(filter, section);
}

fn writeInfo(server: *Server, writer: *std.Io.Writer, filter: []const u8) !void {
    const now = server.clock.now().toMilliseconds();
    const uptime_seconds: i64 = @max(@divTrunc(now - server.createdTime, 1000), 0);
    const memory = server.get_memory_stats();
    const counters = server.store.counters;
    const aof_fsync = server.aof_writer.lastFsyncInfo();
    const rewrite = server.aof_writer.rewriteInfo();

    server.stats.updateOps(server.io);

    if (infoSectionSelected(filter, "server")) {
        try writer.print(
            "# Server\r\n" ++
                "redis_version:{s}\r\n" ++
                "zedis_version:{s}\r\n" ++
                "redis_mode:standalone\r\n" ++
                "os:{s}\r\n" ++
                "arch_bits:{d}\r\n" ++
                "process_id:{d}\r\n" ++
                "run_id:{s}\r\n" ++
                "tcp_port:{d}\r\n" ++
                "uptime_in_seconds:{d}\r\n" ++
                "uptime_in_days:{d}\r\n" ++
                "hz:10\r\n" ++
                "configured_hz:10\r\n" ++
                "executable:zedis\r\n" ++
                "config_file:{s}\r\n" ++
                "io_threads_active:0\r\n\r\n",
            .{
                server_version,
                server_version,
                @tagName(builtin.os.tag),
                @bitSizeOf(usize),
                processId(),
                &server.run_id,
                server.config.port,
                uptime_seconds,
                @divTrunc(uptime_seconds, 86400),
                server.config.config_file orelse "",
            },
        );
    }

    if (infoSectionSelected(filter, "clients")) {
        try writer.print(
            "# Clients\r\n" ++
                "connected_clients:{d}\r\n" ++
                "cluster_connections:0\r\n" ++
                "maxclients:{d}\r\n" ++
                "blocked_clients:0\r\n" ++
                "tracking_clients:0\r\n" ++
                "pubsub_clients:{d}\r\n" ++
                "watching_clients:0\r\n" ++
                "clients_in_timeout_table:0\r\n\r\n",
            .{ connectedClientCount(server), server.config.max_clients, pubsubClientCount(server) },
        );
    }

    if (infoSectionSelected(filter, "memory")) {
        const peak = memory.fixed_memory_used + server.kv_allocator.get_peak_usage();
        const rss = residentSetSize();
        const fragmentation = if (memory.total_allocated == 0)
            0.0
        else
            @as(f64, @floatFromInt(rss)) / @as(f64, @floatFromInt(memory.total_allocated));
        try writer.print(
            "# Memory\r\n" ++
                "used_memory:{d}\r\n" ++
                "used_memory_human:{d}B\r\n" ++
                "used_memory_peak:{d}\r\n" ++
                "used_memory_dataset:{d}\r\n" ++
                "used_memory_rss:{d}\r\n" ++
                "maxmemory:{d}\r\n" ++
                "maxmemory_human:{d}B\r\n" ++
                "maxmemory_policy:{s}\r\n" ++
                "mem_fragmentation_ratio:{d:.2}\r\n" ++
                "mem_allocator:zedis\r\n\r\n",
            .{
                memory.total_allocated,
                memory.total_allocated,
                peak,
                memory.kv_memory_used,
                rss,
                server.config.kv_memory_budget,
                server.config.kv_memory_budget,
                evictionPolicyName(server.config.eviction_policy),
                fragmentation,
            },
        );
    }

    if (infoSectionSelected(filter, "persistence")) {
        try writer.print(
            "# Persistence\r\n" ++
                "loading:0\r\n" ++
                "async_loading:0\r\n" ++
                "rdb_changes_since_last_save:{d}\r\n" ++
                "rdb_bgsave_in_progress:0\r\n" ++
                "rdb_last_save_time:{d}\r\n" ++
                "rdb_last_bgsave_status:ok\r\n" ++
                "aof_enabled:{d}\r\n" ++
                "aof_rewrite_in_progress:{d}\r\n" ++
                "aof_rewrite_scheduled:0\r\n" ++
                "aof_last_bgrewrite_status:{s}\r\n" ++
                "aof_last_write_status:{s}\r\n" ++
                "aof_current_size:{d}\r\n" ++
                "aof_base_size:{d}\r\n" ++
                "aof_pending_bytes:{d}\r\n" ++
                "aof_last_fsync_status:{s}\r\n" ++
                "aof_last_fsync_time:{d}\r\n" ++
                "aof_last_fsync_duration_us:{d}\r\n" ++
                "aof_fsync_count:{d}\r\n" ++
                "aof_rewrites:{d}\r\n" ++
                "aof_last_rewrite_time:{d}\r\n\r\n",
            .{
                server.stats.rdb_changes_since_last_save,
                server.stats.rdb_last_save_time,
                @intFromBool(server.aof_writer.enabled),
                @intFromBool(rewrite.active),
                if (rewrite.last_ok) "ok" else "err",
                if (server.aof_writer.failure() != null) "err" else "ok",
                server.aof_writer.currentSize(),
                server.aof_writer.baseSize(),
                server.aof_writer.pendingBytes(),
                if (server.aof_writer.fsyncFailed()) "err" else "ok",
                aof_fsync.seconds,
                aof_fsync.duration_us,
                aof_fsync.count,
                rewrite.count,
                rewrite.last_seconds,
            },
        );
    }

    if (infoSectionSelected(filter, "stats")) {
        try writer.print(
            "# Stats\r\n" ++
                "total_connections_received:{d}\r\n" ++
                "total_commands_processed:{d}\r\n" ++
                "instantaneous_ops_per_sec:{d}\r\n" ++
                "total_net_input_bytes:{d}\r\n" ++
                "total_net_output_bytes:{d}\r\n" ++
                "rejected_connections:{d}\r\n" ++
                "expired_keys:{d}\r\n" ++
                "evicted_keys:{d}\r\n" ++
                "keyspace_hits:{d}\r\n" ++
                "keyspace_misses:{d}\r\n" ++
                "pubsub_channels:{d}\r\n" ++
                "pubsub_patterns:0\r\n" ++
                "latest_fork_usec:0\r\n\r\n",
            .{
                client_module.total_connections_received(),
                server.stats.commands_processed,
                server.stats.instantaneous_ops_per_sec,
                server.stats.total_net_input_bytes,
                server.stats.total_net_output_bytes,
                server.stats.rejected_connections,
                counters.expired_keys,
                counters.evicted_keys,
                counters.keyspace_hits,
                counters.keyspace_misses,
                server.get_channel_count(),
            },
        );
    }

    if (infoSectionSelected(filter, "replication")) {
        try writer.print(
            "# Replication\r\n" ++
                "role:master\r\n" ++
                "connected_slaves:0\r\n" ++
                "master_failover_state:no-failover\r\n" ++
                "master_replid:0000000000000000000000000000000000000000\r\n" ++
                "master_repl_offset:0\r\n" ++
                "repl_backlog_active:0\r\n" ++
                "repl_backlog_size:1048576\r\n" ++
                "repl_backlog_first_byte_offset:0\r\n" ++
                "repl_backlog_histlen:0\r\n\r\n",
            .{},
        );
    }

    if (infoSectionSelected(filter, "cpu")) {
        const cpu = cpuTimes();
        try writer.print(
            "# CPU\r\nused_cpu_sys:{d:.6}\r\nused_cpu_user:{d:.6}\r\n\r\n",
            .{ cpu.sys, cpu.user },
        );
    }

    if (infoSectionSelected(filter, "modules")) {
        try writer.print("# Modules\r\n\r\n", .{});
    }

    if (infoSectionSelected(filter, "errorstats")) {
        try writer.print("# Errorstats\r\n\r\n", .{});
    }

    if (infoSectionSelected(filter, "commandstats")) {
        try writeCommandStats(server, writer);
    }

    if (infoSectionSelected(filter, "latencystats")) {
        try writer.print("# Latencystats\r\n\r\n", .{});
    }

    if (infoSectionSelected(filter, "cluster")) {
        try writer.print("# Cluster\r\ncluster_enabled:0\r\n\r\n", .{});
    }

    if (infoSectionSelected(filter, "keyspace")) {
        try writeKeyspaceInfo(server, writer);
    }
}

fn writeCommandStats(server: *Server, writer: *std.Io.Writer) !void {
    try writer.print("# Commandstats\r\n", .{});
    var iterator = server.stats.per_command.iterator();
    while (iterator.next()) |entry| {
        const stat = entry.value_ptr.*;
        const per_call = if (stat.calls == 0)
            0.0
        else
            @as(f64, @floatFromInt(stat.usec)) / @as(f64, @floatFromInt(stat.calls));
        try writer.print(
            "cmdstat_{s}:calls={d},usec={d},usec_per_call={d:.2},rejected_calls=0,failed_calls={d}\r\n",
            .{ entry.key_ptr.*, stat.calls, stat.usec, per_call, stat.errors },
        );
    }
    try writer.print("\r\n", .{});
}

fn processId() i64 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        .windows => 0,
        else => std.c.getpid(),
    };
}

fn cpuTimes() struct { sys: f64, user: f64 } {
    if (comptime builtin.os.tag == .windows) return .{ .sys = 0, .user = 0 };
    const usage = std.posix.getrusage(0);
    return .{
        .sys = @as(f64, @floatFromInt(usage.stime.sec)) + @as(f64, @floatFromInt(usage.stime.usec)) / 1_000_000.0,
        .user = @as(f64, @floatFromInt(usage.utime.sec)) + @as(f64, @floatFromInt(usage.utime.usec)) / 1_000_000.0,
    };
}

fn residentSetSize() u64 {
    if (comptime builtin.os.tag == .windows) return 0;
    const usage = std.posix.getrusage(0);
    const rss = @max(usage.maxrss, 0);
    return switch (builtin.os.tag) {
        // Linux reports KiB, the BSDs and macOS report bytes.
        .linux => @as(u64, @intCast(rss)) * 1024,
        else => @intCast(rss),
    };
}

fn writeKeyspaceInfo(server: *Server, writer: *std.Io.Writer) !void {
    var keys: u64 = 0;
    var expires: u64 = 0;
    var iterator = server.store.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        if (index % 1024 == 0 and server.store.commandExpired()) return error.CommandTimeout;
        keys += 1;
        if (entry.expires_at != null) expires += 1;
    }

    try writer.print("# Keyspace\r\n", .{});
    if (keys > 0) {
        try writer.print("db0:keys={d},expires={d},avg_ttl=0\r\n", .{ keys, expires });
    }
    try writer.print("\r\n", .{});
}

fn evictionPolicyName(policy: Config.EvictionPolicy) []const u8 {
    return switch (policy) {
        .noeviction => "noeviction",
        .allkeys_lru => "allkeys-lru",
        .volatile_lru => "volatile-lru",
    };
}

fn connectedClientCount(server: *Server) usize {
    var count: usize = 0;
    for (server.client_slots) |*slot| {
        if (slot.state.load(.acquire) == .active) count += 1;
    }
    return count;
}

fn pubsubClientCount(server: *Server) usize {
    var count: usize = 0;
    for (server.client_slots) |*slot| {
        if (slot.state.load(.acquire) == .active and slot.client.is_in_pubsub_mode) count += 1;
    }
    return count;
}

// --- SLOWLOG ---

pub fn slowlog_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const subcommand = if (args.len > 1) args[1].as_slice() else "";

    if (std.ascii.eqlIgnoreCase(subcommand, "GET")) {
        var requested: isize = 10;
        if (args.len > 2) requested = args[2].as_int() catch -1;
        const count: usize = if (requested < 0)
            client.server.slowlog.lenCount()
        else
            @min(@as(usize, @intCast(requested)), client.server.slowlog.lenCount());

        try resp.write_list_len(writer, count);
        for (0..count) |index| {
            const entry = client.server.slowlog.at(index).?;
            try resp.write_list_len(writer, 6);
            try resp.write_int(writer, @as(i64, @intCast(entry.id)));
            try resp.write_int(writer, entry.timestamp);
            try resp.write_int(writer, @as(i64, @intCast(entry.duration_us)));
            try resp.write_list_len(writer, entry.args.len);
            for (entry.args) |arg| try resp.write_bulk_string(writer, arg);
            try resp.write_bulk_string(writer, entry.client_addr);
            try resp.write_bulk_string(writer, entry.client_name);
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "LEN")) {
        try resp.write_int(writer, @as(i64, @intCast(client.server.slowlog.lenCount())));
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "RESET")) {
        client.server.slowlog.clear();
        try resp.write_ok(writer);
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "HELP")) {
        const lines = [_][]const u8{
            "SLOWLOG GET [count] -- Return the slowest recent commands.",
            "SLOWLOG LEN -- Return the number of entries.",
            "SLOWLOG RESET -- Clear the slow log.",
            "SLOWLOG HELP -- Show this help.",
        };
        try resp.write_list_len(writer, lines.len);
        for (lines) |line| try resp.write_bulk_string(writer, line);
        return;
    }

    try resp.write_error(writer, "ERR Unknown subcommand or wrong number of arguments for SLOWLOG");
}

// --- LATENCY ---

pub fn latency_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const subcommand = if (args.len > 1) args[1].as_slice() else "";
    const monitor = &client.server.latency;

    if (std.ascii.eqlIgnoreCase(subcommand, "LATEST")) {
        var present: usize = 0;
        for (&monitor.events) |*event| {
            if (event.latest() != null) present += 1;
        }
        try resp.write_list_len(writer, present);
        for (&monitor.events) |*event| {
            const sample = event.latest() orelse continue;
            try resp.write_list_len(writer, 4);
            try resp.write_bulk_string(writer, event.name);
            try resp.write_int(writer, sample.timestamp);
            try resp.write_int(writer, @as(i64, @intCast(sample.latency_ms)));
            try resp.write_int(writer, @as(i64, @intCast(event.max)));
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "HISTORY")) {
        if (args.len != 3) {
            try resp.write_error(writer, "ERR wrong number of arguments for LATENCY HISTORY");
            return;
        }
        const event = monitor.getConst(args[2].as_slice()) orelse {
            try resp.write_list_len(writer, 0);
            return;
        };
        var samples: [Stats.sample_ring_len]Stats.LatencySample = undefined;
        const history = event.history(&samples);
        try resp.write_list_len(writer, history.len);
        for (history) |sample| {
            try resp.write_list_len(writer, 2);
            try resp.write_int(writer, sample.timestamp);
            try resp.write_int(writer, @as(i64, @intCast(sample.latency_ms)));
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "RESET")) {
        if (args.len == 2) {
            const count = monitor.reset(null);
            try resp.write_int(writer, @as(i64, @intCast(count)));
            return;
        }
        var reset: usize = 0;
        for (args[2..]) |arg| reset += monitor.reset(arg.as_slice());
        try resp.write_int(writer, @as(i64, @intCast(reset)));
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "DOCTOR")) {
        try resp.write_bulk_string(writer, latencyDoctor(monitor));
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "HELP")) {
        const lines = [_][]const u8{
            "LATENCY LATEST -- Latest latency event per event type.",
            "LATENCY HISTORY <event> -- Latency samples for an event.",
            "LATENCY RESET [event ...] -- Clear latency history.",
            "LATENCY DOCTOR -- Human-readable latency advice.",
            "LATENCY HELP -- Show this help.",
        };
        try resp.write_list_len(writer, lines.len);
        for (lines) |line| try resp.write_bulk_string(writer, line);
        return;
    }

    try resp.write_error(writer, "ERR Unknown subcommand or wrong number of arguments for LATENCY");
}

fn latencyDoctor(monitor: *Stats.LatencyMonitor) []const u8 {
    for (&monitor.events) |*event| {
        const sample = event.latest() orelse continue;
        if (sample.latency_ms >= 100) {
            return "Dave, I detected commands taking over 100ms. Check SLOWLOG for the offending commands, and prefer SCAN over KEYS for large keyspaces.";
        }
    }
    return "Dave, no latency spikes above 100ms have been recorded. I have a good feeling about this.";
}

// --- SHUTDOWN ---

pub fn shutdown_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    if (args.len > 2) {
        try resp.write_error(writer, "ERR wrong number of arguments for SHUTDOWN");
        return;
    }

    if (args.len == 2) {
        const mode = args[1].as_slice();
        if (std.ascii.eqlIgnoreCase(mode, "SAVE")) {
            const rdb = @import("rdb.zig");
            try rdb.save(client, args, writer);
            client.server.requestShutdown(client.slot_handle);
            return;
        }
        if (!std.ascii.eqlIgnoreCase(mode, "NOSAVE")) {
            try resp.write_error(writer, "ERR syntax error");
            return;
        }
    }

    try resp.write_ok(writer);
    client.server.requestShutdown(client.slot_handle);
}

// --- BGREWRITEAOF ---

/// Starts rewriting the AOF as a snapshot of the dataset on a background
/// thread. The reply only says it started; progress and the outcome are in
/// `INFO persistence` (`aof_rewrite_in_progress`, `aof_last_bgrewrite_status`).
pub fn bgrewriteaof(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    _ = args;
    client.server.start_aof_rewrite() catch |err| {
        try resp.write_error(writer, switch (err) {
            error.AofDisabled => "ERR appendonly is disabled",
            error.RewriteInProgress => "ERR Background append only file rewriting already in progress",
            error.AofFailing => "ERR the AOF is failing; a rewrite cannot start",
            else => "ERR could not start the AOF rewrite",
        });
        return;
    };
    try resp.write_simple_string(writer, "Background append only file rewriting started");
}

// --- COMMAND ---

pub fn command_cmd(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const registry = client.command_registry;

    if (args.len == 1) {
        try resp.write_list_len(writer, registry.commands.count());
        var iterator = registry.commands.iterator();
        while (iterator.next()) |entry| {
            try writeCommandInfo(writer, entry.value_ptr.*);
        }
        return;
    }

    const subcommand = args[1].as_slice();

    if (std.ascii.eqlIgnoreCase(subcommand, "COUNT")) {
        if (args.len != 2) return resp.write_error(writer, "ERR wrong number of arguments for 'command|count' command");
        return resp.write_int(writer, registry.commands.count());
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "LIST")) {
        if (args.len != 2) return resp.write_error(writer, "ERR syntax error");
        try resp.write_list_len(writer, registry.commands.count());
        var iterator = registry.commands.iterator();
        while (iterator.next()) |entry| {
            try resp.write_bulk_string(writer, entry.key_ptr.*);
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "INFO")) {
        if (args.len == 2) {
            try resp.write_list_len(writer, registry.commands.count());
            var iterator = registry.commands.iterator();
            while (iterator.next()) |entry| {
                try writeCommandInfo(writer, entry.value_ptr.*);
            }
            return;
        }

        try resp.write_list_len(writer, args.len - 2);
        for (args[2..]) |name| {
            if (lookupCommand(registry, name.as_slice())) |info| {
                try writeCommandInfo(writer, info);
            } else {
                try resp.write_null(writer);
            }
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "DOCS")) {
        var names: usize = 0;
        if (args.len > 2) {
            for (args[2..]) |name| {
                if (lookupCommand(registry, name.as_slice()) != null) names += 1;
            }
        } else {
            names = registry.commands.count();
        }

        try resp.write_map_len(writer, names);
        if (args.len > 2) {
            for (args[2..]) |name| {
                const info = lookupCommand(registry, name.as_slice()) orelse continue;
                try writeCommandDocs(writer, info);
            }
        } else {
            var iterator = registry.commands.iterator();
            while (iterator.next()) |entry| {
                try writeCommandDocs(writer, entry.value_ptr.*);
            }
        }
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "GETKEYS")) {
        if (args.len < 3) return resp.write_error(writer, "ERR Unknown subcommand or wrong number of arguments for 'GETKEYS'. Try COMMAND HELP.");
        const info = lookupCommand(registry, args[2].as_slice()) orelse
            return resp.write_error(writer, "ERR Invalid command specified");

        const key_spec = commandKeySpec(info.name);
        if (key_spec.first == 0) return resp.write_list_len(writer, 0);

        var key_count: usize = 0;
        const command_args = args[2..];
        var index = key_spec.first;
        while (true) {
            const position: usize = if (index < 0)
                @intCast(@as(i64, @intCast(command_args.len)) + index)
            else
                @intCast(index);
            if (position >= command_args.len) break;
            key_count += 1;
            if (key_spec.last >= 0 and index >= key_spec.last) break;
            index += key_spec.step;
        }

        try resp.write_list_len(writer, key_count);
        index = key_spec.first;
        while (true) {
            const position: usize = if (index < 0)
                @intCast(@as(i64, @intCast(command_args.len)) + index)
            else
                @intCast(index);
            if (position >= command_args.len) break;
            try resp.write_bulk_string(writer, command_args[position].as_slice());
            if (key_spec.last >= 0 and index >= key_spec.last) break;
            index += key_spec.step;
        }
        return;
    }

    try resp.write_error(writer, "ERR Unknown subcommand or wrong number of arguments for COMMAND");
}

fn lookupCommand(registry: *CommandRegistry, name: []const u8) ?*const CommandInfo {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return null;
    const upper_name = std.ascii.upperString(&buf, name);
    return registry.commands.getPtr(upper_name);
}

fn commandArity(info: anytype) i64 {
    if (info.max_args) |max_args| {
        if (max_args == info.min_args) return @intCast(info.min_args);
    }
    return -@as(i64, @intCast(info.min_args));
}

const KeySpec = struct {
    first: i64,
    last: i64,
    step: i64,
};

fn commandKeySpec(name: []const u8) KeySpec {
    const no_key = [_][]const u8{
        "PING",    "ECHO",     "QUIT",    "HELP",   "HELLO",  "AUTH",
        "CONFIG",  "INFO",     "COMMAND", "SELECT", "CLIENT", "DBSIZE",
        "FLUSHDB", "FLUSHALL", "SAVE",    "KEYS",   "SCAN",   "RANDOMKEY",
    };
    for (no_key) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return .{ .first = 0, .last = 0, .step = 0 };
    }

    const all_keys = [_][]const u8{ "DEL", "UNLINK", "EXISTS", "MGET" };
    for (all_keys) |candidate| {
        if (std.ascii.eqlIgnoreCase(name, candidate)) return .{ .first = 1, .last = -1, .step = 1 };
    }

    if (std.ascii.eqlIgnoreCase(name, "MSET")) return .{ .first = 1, .last = -1, .step = 2 };
    if (std.ascii.eqlIgnoreCase(name, "RENAME")) return .{ .first = 1, .last = 2, .step = 1 };

    return .{ .first = 1, .last = 1, .step = 1 };
}

fn writeCommandInfo(writer: *std.Io.Writer, info: anytype) !void {
    try resp.write_list_len(writer, 10);
    try resp.write_bulk_string(writer, info.name);
    try resp.write_int(writer, commandArity(info));

    var flag_count: usize = 1;
    if (info.denyoom) flag_count += 1;
    try resp.write_list_len(writer, flag_count);
    try resp.write_simple_string(writer, if (info.write_to_aof) "write" else "readonly");
    if (info.denyoom) try resp.write_simple_string(writer, "denyoom");

    const key_spec = commandKeySpec(info.name);
    try resp.write_int(writer, key_spec.first);
    try resp.write_int(writer, key_spec.last);
    try resp.write_int(writer, key_spec.step);

    try resp.write_list_len(writer, 0); // acl categories
    try resp.write_list_len(writer, 0); // tips
    try resp.write_list_len(writer, 0); // key specs
    try resp.write_list_len(writer, 0); // subcommands
}

fn writeCommandDocs(writer: *std.Io.Writer, info: anytype) !void {
    try resp.write_bulk_string(writer, info.name);
    try resp.write_map_len(writer, 4);
    try resp.write_bulk_string(writer, "summary");
    try resp.write_bulk_string(writer, info.description);
    try resp.write_bulk_string(writer, "since");
    try resp.write_bulk_string(writer, "1.0.0");
    try resp.write_bulk_string(writer, "group");
    try resp.write_bulk_string(writer, "generic");
    try resp.write_bulk_string(writer, "arity");
    try resp.write_int(writer, commandArity(info));
}
