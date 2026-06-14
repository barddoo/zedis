const std = @import("std");
const Client = @import("../client.zig").Client;
const Config = @import("../config.zig");
const Value = @import("../parser.zig").Value;
const resp = @import("../commands/resp.zig");
const string_match = @import("../util/string_match.zig").string_match;

const Writer = std.Io.Writer;

const ConfigParameter = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    mutable: bool = false,
};

const config_parameters = [_]ConfigParameter{
    .{ .name = "acllog-max-len" },
    .{ .name = "aof-load-broken" },
    .{ .name = "aof-load-broken-max-size" },
    .{ .name = "aof-load-truncated" },
    .{ .name = "aof-use-rdb-preamble" },
    .{ .name = "aof-write-buffer-size", .mutable = true },
    .{ .name = "appenddirname" },
    .{ .name = "appendfilename" },
    .{ .name = "appendfsync" },
    .{ .name = "appendonly" },
    .{ .name = "auto-aof-rewrite-min-size" },
    .{ .name = "auto-aof-rewrite-percentage" },
    .{ .name = "bind" },
    .{ .name = "clock-update-ms" },
    .{ .name = "daemonize" },
    .{ .name = "dbfilename" },
    .{ .name = "dir" },
    .{ .name = "disable-thp" },
    .{ .name = "initial-capacity" },
    .{ .name = "lazyfree-lazy-eviction" },
    .{ .name = "lazyfree-lazy-expire" },
    .{ .name = "lazyfree-lazy-server-del" },
    .{ .name = "lazyfree-lazy-user-del" },
    .{ .name = "lazyfree-lazy-user-flush" },
    .{ .name = "logfile" },
    .{ .name = "loglevel" },
    .{ .name = "max-channels", .mutable = true },
    .{ .name = "max-subscribers-per-channel", .mutable = true },
    .{ .name = "maxclients", .aliases = &.{"max-clients"} },
    .{ .name = "maxmemory", .aliases = &.{"kv-memory-budget"} },
    .{ .name = "maxmemory-policy", .aliases = &.{"eviction-policy"}, .mutable = true },
    .{ .name = "maxmemory-samples", .mutable = true },
    .{ .name = "no-appendfsync-on-rewrite" },
    .{ .name = "oom-score-adj" },
    .{ .name = "pidfile" },
    .{ .name = "port" },
    .{ .name = "protected-mode", .mutable = true },
    .{ .name = "rdb-del-sync-files" },
    .{ .name = "rdb-write-buffer-size", .mutable = true },
    .{ .name = "rdbchecksum", .mutable = true },
    .{ .name = "rdbcompression", .mutable = true },
    .{ .name = "repl-disable-tcp-nodelay" },
    .{ .name = "repl-diskless-load" },
    .{ .name = "repl-diskless-sync", .mutable = true },
    .{ .name = "repl-diskless-sync-delay", .mutable = true },
    .{ .name = "repl-diskless-sync-max-replicas" },
    .{ .name = "replica-lazy-flush" },
    .{ .name = "replica-priority" },
    .{ .name = "replica-read-only", .mutable = true },
    .{ .name = "replica-serve-stale-data", .mutable = true },
    .{ .name = "requirepass", .mutable = true },
    .{ .name = "save" },
    .{ .name = "stop-writes-on-bgsave-error", .mutable = true },
    .{ .name = "tcp-backlog" },
    .{ .name = "tcp-keepalive", .mutable = true },
    .{ .name = "temp-arena-size" },
    .{ .name = "timeout", .mutable = true },
};

const Clock = @import("../clock.zig");
const Store = @import("../store.zig").Store;
const KeyValueAllocator = @import("../kv_allocator.zig");
const Server = @import("../server.zig");
const Io = std.Io;
const testing = std.testing;

const ConfigSetError = error{
    UnknownParameter,
    ImmutableParameter,
    InvalidValue,
};

// PING command implementation
pub fn ping(writer: *std.Io.Writer, args: []const Value) !void {
    if (args.len == 1) {
        try resp.writeSimpleString(writer, "PONG");
    } else {
        try resp.writeBulkString(writer, args[1].asSlice());
    }
}

// ECHO command implementation
pub fn echo(writer: *std.Io.Writer, args: []const Value) !void {
    try resp.writeBulkString(writer, args[1].asSlice());
}

// QUIT command implementation
pub fn quit(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    _ = args; // Unused parameter
    try resp.writeOK(writer);
    client.connection.close(client.io);
}

pub fn auth(client: *Client, args: []const Value, writer: *std.Io.Writer) !void {
    const password = args[1].asSlice();

    if (!client.server.config.requiresAuth()) {
        return error.AuthNoPasswordSet;
    }

    if (std.mem.eql(u8, password, client.server.config.requirepass.?)) {
        client.authenticated = true;
        try resp.writeOK(writer);
    } else {
        client.authenticated = false;
        return error.AuthInvalidPassword;
    }
}

pub fn config(client: *Client, args: []const Value, writer: *Writer) !void {
    const subcommand = args[1].asSlice();

    if (std.ascii.eqlIgnoreCase(subcommand, "GET")) {
        if (args.len != 3) {
            try resp.writeError(writer, "wrong number of arguments for CONFIG GET");
            return;
        }
        try configGet(client, args[2].asSlice(), writer);
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "SET")) {
        if (args.len < 4 or @mod(args.len, 2) != 0) {
            try resp.writeError(writer, "wrong number of arguments for CONFIG SET");
            return;
        }
        try configSet(client, args[2..], writer);
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "RESETSTAT")) {
        if (args.len != 2) {
            try resp.writeError(writer, "wrong number of arguments for CONFIG RESETSTAT");
            return;
        }
        try resp.writeOK(writer);
        return;
    }

    if (std.ascii.eqlIgnoreCase(subcommand, "HELP")) {
        if (args.len != 2) {
            try resp.writeError(writer, "wrong number of arguments for CONFIG HELP");
            return;
        }
        try configHelp(writer);
        return;
    }

    try resp.writeError(writer, "Unknown subcommand or wrong number of arguments for CONFIG");
}

fn configGet(client: *Client, pattern: []const u8, writer: *Writer) !void {
    const lowered_pattern = try std.ascii.allocLowerString(client.allocator, pattern);
    defer client.allocator.free(lowered_pattern);

    var count: usize = 0;
    for (config_parameters) |param| {
        if (parameterMatchesPattern(param, lowered_pattern)) {
            count += 1;
        }
    }

    try resp.writeListLen(writer, count * 2);

    for (config_parameters) |param| {
        if (!parameterMatchesPattern(param, lowered_pattern)) continue;
        try resp.writeBulkString(writer, param.name);
        try writeConfigValue(client, writer, param.name);
    }
}

fn configSet(client: *Client, pairs: []const Value, writer: *Writer) !void {
    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const name = pairs[i].asSlice();
        const value = pairs[i + 1].asSlice();
        applyConfigSet(client, name, value) catch |err| switch (err) {
            error.UnknownParameter => {
                try writer.print("-ERR Unknown option or number of arguments for CONFIG SET - '{s}'\r\n", .{name});
                return;
            },
            error.ImmutableParameter => {
                try writer.print("-ERR CONFIG SET does not support runtime updates for '{s}'\r\n", .{name});
                return;
            },
            error.InvalidValue => {
                try writer.print("-ERR Invalid argument '{s}' for CONFIG SET '{s}'\r\n", .{ value, name });
                return;
            },
        };
    }

    try resp.writeOK(writer);
}

fn configHelp(writer: *Writer) !void {
    const lines = [_][]const u8{
        "CONFIG GET <pattern> -- Return configuration parameters matching a glob pattern.",
        "CONFIG SET <name> <value> [name value ...] -- Update supported runtime configuration parameters.",
        "CONFIG RESETSTAT -- Reset statistics counters. Zedis currently treats this as a no-op.",
        "CONFIG HELP -- Show this help.",
    };

    try resp.writeListLen(writer, lines.len);
    for (lines) |line| {
        try resp.writeBulkString(writer, line);
    }
}

fn parameterMatchesPattern(param: ConfigParameter, lowered_pattern: []const u8) bool {
    if (string_match(lowered_pattern, param.name)) return true;

    if (std.mem.indexOfAny(u8, lowered_pattern, "*?") != null) return false;
    for (param.aliases) |alias| {
        if (std.mem.eql(u8, lowered_pattern, alias)) return true;
    }
    return false;
}

fn findConfigParameter(name: []const u8) ?ConfigParameter {
    for (config_parameters) |param| {
        if (std.ascii.eqlIgnoreCase(name, param.name)) return param;
        for (param.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(name, alias)) return param;
        }
    }
    return null;
}

fn writeConfigValue(client: *Client, writer: *Writer, name: []const u8) !void {
    const server_config = client.server.config;

    if (std.mem.eql(u8, name, "appenddirname")) {
        try resp.writeBulkString(writer, server_config.appenddirname);
    } else if (std.mem.eql(u8, name, "appendfilename")) {
        try resp.writeBulkString(writer, server_config.appendfilename);
    } else if (std.mem.eql(u8, name, "appendfsync")) {
        try resp.writeBulkString(writer, server_config.appendfsync);
    } else if (std.mem.eql(u8, name, "aof-write-buffer-size")) {
        try writeConfigInt(writer, server_config.aof_write_buffer_size);
    } else if (std.mem.eql(u8, name, "appendonly")) {
        try writeConfigBool(writer, server_config.appendonly);
    } else if (std.mem.eql(u8, name, "bind")) {
        try resp.writeBulkString(writer, server_config.bind);
    } else if (std.mem.eql(u8, name, "clock-update-ms")) {
        try writeConfigInt(writer, server_config.clock_update_ms);
    } else if (std.mem.eql(u8, name, "daemonize")) {
        try writeConfigBool(writer, server_config.daemonize);
    } else if (std.mem.eql(u8, name, "dbfilename")) {
        try resp.writeBulkString(writer, server_config.dbfilename);
    } else if (std.mem.eql(u8, name, "dir")) {
        try resp.writeBulkString(writer, server_config.dir);
    } else if (std.mem.eql(u8, name, "initial-capacity")) {
        try writeConfigInt(writer, server_config.initial_capacity);
    } else if (std.mem.eql(u8, name, "logfile")) {
        try resp.writeBulkString(writer, server_config.logfile);
    } else if (std.mem.eql(u8, name, "loglevel")) {
        try resp.writeBulkString(writer, server_config.loglevel);
    } else if (std.mem.eql(u8, name, "max-channels")) {
        try writeConfigInt(writer, server_config.max_channels);
    } else if (std.mem.eql(u8, name, "max-subscribers-per-channel")) {
        try writeConfigInt(writer, server_config.max_subscribers_per_channel);
    } else if (std.mem.eql(u8, name, "maxclients")) {
        try writeConfigInt(writer, server_config.max_clients);
    } else if (std.mem.eql(u8, name, "maxmemory")) {
        try writeConfigInt(writer, server_config.kv_memory_budget);
    } else if (std.mem.eql(u8, name, "maxmemory-policy")) {
        try resp.writeBulkString(writer, evictionPolicyName(server_config.eviction_policy));
    } else if (std.mem.eql(u8, name, "maxmemory-samples")) {
        try writeConfigInt(writer, server_config.maxmemory_samples);
    } else if (std.mem.eql(u8, name, "pidfile")) {
        try resp.writeBulkString(writer, server_config.pidfile);
    } else if (std.mem.eql(u8, name, "port")) {
        try writeConfigInt(writer, server_config.port);
    } else if (std.mem.eql(u8, name, "protected-mode")) {
        try writeConfigBool(writer, server_config.protected_mode);
    } else if (std.mem.eql(u8, name, "rdb-write-buffer-size")) {
        try writeConfigInt(writer, server_config.rdb_write_buffer_size);
    } else if (std.mem.eql(u8, name, "rdbchecksum")) {
        try writeConfigBool(writer, server_config.rdbchecksum);
    } else if (std.mem.eql(u8, name, "rdbcompression")) {
        try writeConfigBool(writer, server_config.rdbcompression);
    } else if (std.mem.eql(u8, name, "replica-read-only")) {
        try writeConfigBool(writer, server_config.replica_read_only);
    } else if (std.mem.eql(u8, name, "replica-serve-stale-data")) {
        try writeConfigBool(writer, server_config.replica_serve_stale_data);
    } else if (std.mem.eql(u8, name, "repl-diskless-load")) {
        try resp.writeBulkString(writer, server_config.repl_diskless_load);
    } else if (std.mem.eql(u8, name, "repl-diskless-sync")) {
        try writeConfigBool(writer, server_config.repl_diskless_sync);
    } else if (std.mem.eql(u8, name, "repl-diskless-sync-delay")) {
        try writeConfigInt(writer, server_config.repl_diskless_sync_delay);
    } else if (std.mem.eql(u8, name, "requirepass")) {
        try resp.writeBulkString(writer, server_config.requirepass orelse "");
    } else if (std.mem.eql(u8, name, "save")) {
        try resp.writeBulkString(writer, "");
    } else if (std.mem.eql(u8, name, "stop-writes-on-bgsave-error")) {
        try writeConfigBool(writer, server_config.stop_writes_on_bgsave_error);
    } else if (std.mem.eql(u8, name, "tcp-backlog")) {
        try writeConfigInt(writer, server_config.tcp_backlog);
    } else if (std.mem.eql(u8, name, "tcp-keepalive")) {
        try writeConfigInt(writer, server_config.tcp_keepalive);
    } else if (std.mem.eql(u8, name, "temp-arena-size")) {
        try writeConfigInt(writer, server_config.temp_arena_size);
    } else if (std.mem.eql(u8, name, "timeout")) {
        try writeConfigInt(writer, server_config.timeout);
    } else if (std.mem.eql(u8, name, "acllog-max-len")) {
        try writeConfigInt(writer, server_config.acllog_max_len);
    } else if (std.mem.eql(u8, name, "aof-load-broken")) {
        try writeConfigBool(writer, server_config.aof_load_broken);
    } else if (std.mem.eql(u8, name, "aof-load-broken-max-size")) {
        try writeConfigInt(writer, server_config.aof_load_broken_max_size);
    } else if (std.mem.eql(u8, name, "aof-load-truncated")) {
        try writeConfigBool(writer, server_config.aof_load_truncated);
    } else if (std.mem.eql(u8, name, "aof-use-rdb-preamble")) {
        try writeConfigBool(writer, server_config.aof_use_rdb_preamble);
    } else if (std.mem.eql(u8, name, "auto-aof-rewrite-min-size")) {
        try resp.writeBulkString(writer, server_config.auto_aof_rewrite_min_size);
    } else if (std.mem.eql(u8, name, "auto-aof-rewrite-percentage")) {
        try writeConfigInt(writer, server_config.auto_aof_rewrite_percentage);
    } else if (std.mem.eql(u8, name, "disable-thp")) {
        try writeConfigBool(writer, server_config.disable_thp);
    } else if (std.mem.eql(u8, name, "lazyfree-lazy-eviction")) {
        try writeConfigBool(writer, server_config.lazyfree_lazy_eviction);
    } else if (std.mem.eql(u8, name, "lazyfree-lazy-expire")) {
        try writeConfigBool(writer, server_config.lazyfree_lazy_expire);
    } else if (std.mem.eql(u8, name, "lazyfree-lazy-server-del")) {
        try writeConfigBool(writer, server_config.lazyfree_lazy_server_del);
    } else if (std.mem.eql(u8, name, "lazyfree-lazy-user-del")) {
        try writeConfigBool(writer, server_config.lazyfree_lazy_user_del);
    } else if (std.mem.eql(u8, name, "lazyfree-lazy-user-flush")) {
        try writeConfigBool(writer, server_config.lazyfree_lazy_user_flush);
    } else if (std.mem.eql(u8, name, "no-appendfsync-on-rewrite")) {
        try writeConfigBool(writer, server_config.no_appendfsync_on_rewrite);
    } else if (std.mem.eql(u8, name, "oom-score-adj")) {
        try writeConfigBool(writer, server_config.oom_score_adj);
    } else if (std.mem.eql(u8, name, "rdb-del-sync-files")) {
        try writeConfigBool(writer, server_config.rdb_del_sync_files);
    } else if (std.mem.eql(u8, name, "repl-disable-tcp-nodelay")) {
        try writeConfigBool(writer, server_config.repl_disable_tcp_nodelay);
    } else if (std.mem.eql(u8, name, "repl-diskless-sync-max-replicas")) {
        try writeConfigInt(writer, server_config.repl_diskless_sync_max_replicas);
    } else if (std.mem.eql(u8, name, "replica-lazy-flush")) {
        try writeConfigBool(writer, server_config.replica_lazy_flush);
    } else if (std.mem.eql(u8, name, "replica-priority")) {
        try writeConfigInt(writer, server_config.replica_priority);
    } else {
        unreachable;
    }
}

fn applyConfigSet(client: *Client, name: []const u8, value: []const u8) ConfigSetError!void {
    const param = findConfigParameter(name) orelse return error.UnknownParameter;
    if (!param.mutable) return error.ImmutableParameter;

    if (std.mem.eql(u8, param.name, "aof-write-buffer-size")) {
        client.server.config.aof_write_buffer_size = Config.parseMemorySize(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "max-channels")) {
        client.server.config.max_channels = parseConfigInt(u32, value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "max-subscribers-per-channel")) {
        client.server.config.max_subscribers_per_channel = parseConfigInt(u32, value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "maxmemory-policy")) {
        const policy = parseEvictionPolicy(value) catch return error.InvalidValue;
        client.server.config.eviction_policy = policy;
        client.server.store.eviction_policy = policy;
        client.server.kv_allocator.eviction_policy = policy;
        return;
    }
    if (std.mem.eql(u8, param.name, "maxmemory-samples")) {
        const samples = parseConfigInt(u32, value) catch return error.InvalidValue;
        if (samples == 0) return error.InvalidValue;
        client.server.config.maxmemory_samples = samples;
        client.server.store.maxmemory_samples = @intCast(samples);
        return;
    }
    if (std.mem.eql(u8, param.name, "protected-mode")) {
        client.server.config.protected_mode = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "rdb-write-buffer-size")) {
        client.server.config.rdb_write_buffer_size = Config.parseMemorySize(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "rdbchecksum")) {
        client.server.config.rdbchecksum = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "rdbcompression")) {
        client.server.config.rdbcompression = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "replica-read-only")) {
        client.server.config.replica_read_only = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "replica-serve-stale-data")) {
        client.server.config.replica_serve_stale_data = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "repl-diskless-sync")) {
        client.server.config.repl_diskless_sync = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "repl-diskless-sync-delay")) {
        client.server.config.repl_diskless_sync_delay = parseConfigInt(u32, value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "requirepass")) {
        if (client.server.config.requirepass) |password| {
            client.allocator.free(password);
        }
        client.server.config.requirepass = if (value.len == 0) null else client.allocator.dupe(u8, value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "stop-writes-on-bgsave-error")) {
        client.server.config.stop_writes_on_bgsave_error = parseConfigBool(value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "tcp-keepalive")) {
        client.server.config.tcp_keepalive = parseConfigInt(u32, value) catch return error.InvalidValue;
        return;
    }
    if (std.mem.eql(u8, param.name, "timeout")) {
        client.server.config.timeout = parseConfigInt(u32, value) catch return error.InvalidValue;
        return;
    }

    return error.ImmutableParameter;
}

fn writeConfigBool(writer: *Writer, value: bool) !void {
    try resp.writeBulkString(writer, if (value) "yes" else "no");
}

fn writeConfigInt(writer: *Writer, value: anytype) !void {
    var buffer: [32]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    try resp.writeBulkString(writer, formatted);
}

fn evictionPolicyName(policy: Config.EvictionPolicy) []const u8 {
    return switch (policy) {
        .noeviction => "noeviction",
        .allkeys_lru => "allkeys-lru",
        .volatile_lru => "volatile-lru",
    };
}

fn parseConfigBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) {
        return false;
    }
    return error.InvalidValue;
}

fn parseEvictionPolicy(value: []const u8) !Config.EvictionPolicy {
    if (std.ascii.eqlIgnoreCase(value, "noeviction")) return .noeviction;
    if (std.ascii.eqlIgnoreCase(value, "allkeys-lru")) return .allkeys_lru;
    if (std.ascii.eqlIgnoreCase(value, "volatile-lru")) return .volatile_lru;
    return error.InvalidValue;
}

fn parseConfigInt(comptime T: type, value: []const u8) !T {
    return std.fmt.parseInt(T, value, 10);
}

// HELP command implementation
pub fn help(writer: *std.Io.Writer, args: []const Value) !void {
    _ = args; // Unused parameter
    const help_text =
        \\Zedis Server Commands:
        \\
        \\Connection Commands:
        \\  PING [message]       - Ping the server
        \\  ECHO <message>       - Echo the given string
        \\  QUIT                 - Close the connection
        \\  HELP                 - Show this help message
        \\
        \\String Commands:
        \\  SET <key> <value>    - Set string value of a key
        \\  GET <key>            - Get string value of a key
        \\  INCR <key>           - Increment the value of a key
        \\  DECR <key>           - Decrement the value of a key
    ;

    try resp.writeBulkString(writer, help_text);
}

const TestContext = struct {
    allocator: std.mem.Allocator,
    clock: Clock,
    server: Server,
    client: Client,

    fn init(self: *TestContext, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.clock = Clock.init(testing.io, 0);

        self.server = undefined;
        self.server.config = .{
            .appendonly = false,
            .kv_memory_budget = 4096,
            .maxmemory_samples = 5,
            .eviction_policy = .allkeys_lru,
        };
        self.server.store = try Store.init(allocator, testing.io, &self.clock, .{
            .initial_capacity = 16,
            .eviction_policy = .allkeys_lru,
            .maxmemory_samples = 5,
        });
        self.server.kv_allocator = try KeyValueAllocator.init(allocator, 4096, .allkeys_lru);

        self.client = undefined;
        self.client.allocator = allocator;
        self.client.server = &self.server;
    }

    fn deinit(self: *TestContext) void {
        self.server.store.deinit();
        if (self.server.config.requirepass) |password| {
            self.allocator.free(password);
        }
    }
};

test "CONFIG GET returns exact parameter" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "GET" },
        .{ .data = "appendonly" },
    };

    try config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("*2\r\n$10\r\nappendonly\r\n$2\r\nno\r\n", writer.buffered());
}

test "CONFIG GET resolves exact alias to canonical name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "GET" },
        .{ .data = "kv-memory-budget" },
    };

    try config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("*2\r\n$9\r\nmaxmemory\r\n$4\r\n4096\r\n", writer.buffered());
}

test "CONFIG GET supports wildcard patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    ctx.server.config.maxmemory_samples = 9;
    ctx.server.store.maxmemory_samples = 9;
    ctx.server.config.eviction_policy = .volatile_lru;
    ctx.server.store.eviction_policy = .volatile_lru;

    var buffer: [512]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "GET" },
        .{ .data = "maxmemory*" },
    };

    try config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings(
        "*6\r\n" ++
            "$9\r\nmaxmemory\r\n$4\r\n4096\r\n" ++
            "$16\r\nmaxmemory-policy\r\n$12\r\nvolatile-lru\r\n" ++
            "$17\r\nmaxmemory-samples\r\n$1\r\n9\r\n",
        writer.buffered(),
    );
}

test "CONFIG SET updates supported runtime parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "SET" },
        .{ .data = "maxmemory-samples" },
        .{ .data = "11" },
        .{ .data = "eviction-policy" },
        .{ .data = "noeviction" },
        .{ .data = "requirepass" },
        .{ .data = "secret" },
    };

    try config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("+OK\r\n", writer.buffered());
    try testing.expectEqual(@as(u32, 11), ctx.server.config.maxmemory_samples);
    try testing.expectEqual(@as(usize, 11), ctx.server.store.maxmemory_samples);
    try testing.expectEqual(.noeviction, ctx.server.config.eviction_policy);
    try testing.expectEqual(.noeviction, ctx.server.store.eviction_policy);
    try testing.expectEqual(.noeviction, ctx.server.kv_allocator.eviction_policy);
    try testing.expectEqualStrings("secret", ctx.server.config.requirepass.?);
}

test "CONFIG SET rejects immutable parameters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx: TestContext = undefined;
    try ctx.init(arena.allocator());
    defer ctx.deinit();

    var buffer: [256]u8 = undefined;
    var writer = Writer.fixed(&buffer);

    const args = [_]Value{
        .{ .data = "CONFIG" },
        .{ .data = "SET" },
        .{ .data = "appendonly" },
        .{ .data = "yes" },
    };

    try config(&ctx.client, &args, &writer);

    try testing.expectEqualStrings("-ERR CONFIG SET does not support runtime updates for 'appendonly'\r\n", writer.buffered());
    try testing.expect(!ctx.server.config.appendonly);
}
