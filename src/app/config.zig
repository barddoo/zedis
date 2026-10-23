const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;
const Client = @import("client.zig").Client;
const ClientHandle = @import("../util/types.zig").ClientHandle;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;

const Config = @This();

/// Hard cap for config file reads. Real config files are ~110 KiB; this only
/// guards against accidentally pointing the server at a huge file.
const max_config_bytes = 16 * 1024 * 1024;

pub const EvictionPolicy = enum {
    noeviction, // Return errors when memory limit reached
    allkeys_lru, // Evict least recently used keys
    volatile_lru, // Evict LRU keys with expire set
};

pub const MemoryBudgetSource = enum {
    /// Set by maxmemory/kv-memory-budget in the config file.
    configured,
    /// Derived from the container's cgroup memory limit.
    container,
    /// Fixed default used when no container limit applies.
    default,
};

pub const MemoryStats = struct {
    fixed_memory_used: usize,
    kv_memory_used: usize,
    total_allocated: usize,
    total_budget: usize,

    pub fn usage_percent(self: MemoryStats) u8 {
        return @intCast((self.total_allocated * 100) / self.total_budget);
    }
};

// Network
/// Bind to specific network interfaces.
bind: []const u8 = "127.0.0.1",
/// Enable protected mode for security when no password is set.
protected_mode: bool = true,
/// TCP port to listen on.
port: u16 = 6379,
/// TCP listen backlog.
tcp_backlog: u32 = 511,
/// Close connection after client is idle for N seconds (0 to disable).
timeout: u32 = 0,
/// TCP keepalive interval in seconds.
tcp_keepalive: u32 = 300,

// General
/// Run as a daemon process.
daemonize: bool = false,
/// PID file location when daemonized.
pidfile: []const u8 = "/var/run/redis_6379.pid",
/// Log verbosity level (debug, verbose, notice, warning).
loglevel: []const u8 = "notice",
/// Log file path (empty string for stdout).
logfile: []const u8 = "",
/// Clock update interval in milliseconds.
/// 0 = always use realtime syscall (most accurate, higher CPU)
/// >0 = cache and update every N ms (good performance)
clock_update_ms: u32 = 100,
/// Number of candidates sampled during approximate LRU eviction.
/// Higher values are more accurate and more expensive.
maxmemory_samples: u32 = 5,

// Snapshotting
/// Stop accepting writes if RDB snapshot fails.
stop_writes_on_bgsave_error: bool = true,
/// Compress RDB snapshot files with LZF.
rdbcompression: bool = true,
/// Add CRC64 checksum to RDB files.
rdbchecksum: bool = true,
/// Filename for RDB snapshot.
dbfilename: []const u8 = "dump.rdb",
/// Delete sync files used for replication.
rdb_del_sync_files: bool = false, // (not implemented)
/// Working directory for RDB/AOF files.
dir: []const u8 = "./",

// Replication
/// Serve stale data when replica loses connection to master.
replica_serve_stale_data: bool = true,
/// Make replicas read-only.
replica_read_only: bool = true,
/// Use diskless replication (transfer RDB via socket).
repl_diskless_sync: bool = true,
/// Delay before diskless sync starts (seconds).
repl_diskless_sync_delay: u32 = 5,
/// Max replicas to sync in parallel (0 = unlimited).
repl_diskless_sync_max_replicas: u32 = 0, // (not implemented)
/// How replicas load RDB (disabled, on-empty-db, swapdb).
repl_diskless_load: []const u8 = "disabled",
/// Disable TCP_NODELAY on replica socket.
repl_disable_tcp_nodelay: bool = false, // (not implemented)
/// Priority for replica promotion (lower = higher priority).
replica_priority: u32 = 100, // (not implemented)

// Security
/// Maximum length of ACL log.
acllog_max_len: u32 = 128, // (not implemented)

// Lazy freeing
/// Async free memory for evicted keys.
lazyfree_lazy_eviction: bool = false, // (not implemented)
/// Async free memory for expired keys.
lazyfree_lazy_expire: bool = false, // (not implemented)
/// Async free memory for deleted keys (DEL, RENAME, etc).
lazyfree_lazy_server_del: bool = false, // (not implemented)
/// Async flush replica's database during full resync.
replica_lazy_flush: bool = false, // (not implemented)
/// Async free memory for user-called DEL commands.
lazyfree_lazy_user_del: bool = false, // (not implemented)
/// Async free memory for FLUSHDB/FLUSHALL commands.
lazyfree_lazy_user_flush: bool = false, // (not implemented)

// OOM handling
/// Adjust OOM killer score.
oom_score_adj: bool = false, // (not implemented)
/// OOM score values for different states.
oom_score_adj_values: []const u32 = &[_]u32{ 0, 200, 800 }, // (not implemented)
/// Disable Transparent Huge Pages.
disable_thp: bool = true, // (not implemented)

// Append only mode
/// Enable AOF persistence mode.
appendonly: bool = false,
/// AOF filename.
appendfilename: []const u8 = "appendonly.aof",
/// Directory for AOF files.
appenddirname: []const u8 = "appendonlydir", // (not implemented — use dir instead)
/// AOF fsync policy (always, everysec, no).
appendfsync: []const u8 = "everysec",
/// Disable fsync during BGSAVE or BGREWRITEAOF.
no_appendfsync_on_rewrite: bool = false, // (not implemented)
/// Trigger AOF rewrite when size grows by this percentage.
auto_aof_rewrite_percentage: u32 = 100, // (not implemented)
/// Minimum AOF size to trigger auto rewrite.
auto_aof_rewrite_min_size: []const u8 = "64mb", // (not implemented)
/// Load truncated AOF file on startup.
aof_load_truncated: bool = true, // (not implemented)
/// Allow loading corrupted AOF with warnings.
aof_load_broken: bool = false, // (not implemented)
/// Max size of broken AOF file to load (bytes).
aof_load_broken_max_size: u32 = 4096, // (not implemented)
/// Use RDB preamble in AOF for faster restarts.
aof_use_rdb_preamble: bool = true, // (not implemented)

// Legacy fields
timeout_seconds: u64 = 0,
host: []const u8 = "127.0.0.1",

// Memory and performance configuration (production-ready defaults)
max_clients: u32 = 10000, // Maximum concurrent client connections
max_channels: u32 = 10000, // Maximum pub/sub channels (production: thousands of channels)
max_subscribers_per_channel: u32 = 1000, // Max subscribers per channel (production: hundreds per channel)
/// KV memory budget in bytes. `0` means unlimited (like `maxmemory 0`). When
/// not set in the config file it is 80% of a container's cgroup limit, or a
/// fixed default outside containers.
kv_memory_budget: usize = 0,
/// How `kv_memory_budget` was determined.
memory_budget_source: MemoryBudgetSource = .configured,
/// Set by `maxmemory`/`kv-memory-budget` so auto-sizing leaves the value alone.
kv_memory_budget_explicit: bool = false,
initial_capacity: u32 = 8192, // Initial hash map capacity for Store (reduces early rehashing)
eviction_policy: EvictionPolicy = .allkeys_lru, // LRU eviction policy
requirepass: ?[]const u8 = null, // Password authentication (null = disabled)
rdb_write_buffer_size: usize = 256 * 1024, // 256KB buffer for RDB writes (optimal SSD throughput)

// Computed constants (calculated from other fields)
pub fn client_pool_size(self: Config) usize {
    return self.max_clients * @sizeOf(Client);
}

pub fn pubsub_matrix_size(self: Config) usize {
    return self.max_channels * self.max_subscribers_per_channel * @sizeOf(ClientHandle);
}

pub fn fixed_memory_size(self: Config) usize {
    return self.client_pool_size() + self.pubsub_matrix_size();
}

pub fn total_memory_budget(self: Config) usize {
    return self.fixed_memory_size() + self.kv_memory_budget;
}

pub fn requires_auth(self: Config) bool {
    return self.requirepass != null;
}

/// Runtime options that must be known before the zio runtime is initialized.
/// Read from the config file with blocking I/O at startup; the main async
/// config parse happens afterwards against the already-running runtime.
pub const RuntimePrefs = struct {
    /// zio RuntimeOptions.metrics_log_interval in seconds. 0 disables the
    /// scheduler metrics monitor thread.
    metrics_log_interval_seconds: u32 = 0,
    /// zio RuntimeOptions.stack_pool.prewarm: number of coroutine stack slots
    /// to carve and commit at runtime init. 0 disables prewarming.
    stack_pool_prewarm: u32 = 0,
};

/// Path of the config file passed on the command line, if any.
pub fn find_config_file(allocator: std.mem.Allocator, args: std.process.Args) ?[]const u8 {
    var args_iter = if (builtin.target.os.tag == .windows) args.iterate() else (std.process.Args.Iterator.initAllocator(args, allocator) catch return null);

    _ = args_iter.skip();

    return args_iter.next();
}

pub fn read_config(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !Config {
    var config = if (find_config_file(allocator, args)) |file_name|
        try read_file(allocator, io, file_name)
    else
        Config{};

    // Bounded by default: size the budget from the container/host limit unless
    // the config file set one explicitly.
    try resolve_memory_budget(&config, detect_memory_limit(allocator, io));

    return config;
}

/// Scans the config file (blocking, pre-runtime) for the runtime tuning keys
/// the zio runtime needs at init time. Missing file or keys return defaults.
pub fn read_runtime_prefs(allocator: std.mem.Allocator, args: std.process.Args) RuntimePrefs {
    const file_name = find_config_file(allocator, args) orelse return .{};

    // Blocking startup read (pre-runtime): the global single-threaded Io does
    // file I/O synchronously without needing a zio runtime.
    const io = std.Io.Threaded.global_single_threaded.io();
    const content = read_config_bytes(allocator, io, file_name) catch return .{};
    defer allocator.free(content);

    var prefs: RuntimePrefs = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const key = parts.next() orelse continue;
        const value = parts.rest();

        if (eql(u8, key, "scheduler-metrics-log-interval")) {
            prefs.metrics_log_interval_seconds = parseInt(u32, std.mem.trim(u8, value, " \t\r"), 10) catch continue;
        } else if (eql(u8, key, "stack-pool-prewarm")) {
            prefs.stack_pool_prewarm = parseInt(u32, std.mem.trim(u8, value, " \t\r"), 10) catch continue;
        }
    }

    return prefs;
}

fn read_config_bytes(allocator: std.mem.Allocator, io: std.Io, file_name: []const u8) ![]u8 {
    // Read the whole file: the previous fixed 8 KiB stack buffer silently
    // dropped every directive past the first ~250 lines.
    return Dir.cwd().readFileAlloc(io, file_name, allocator, .limited(max_config_bytes));
}

fn read_file(allocator: std.mem.Allocator, io: std.Io, file_name: []const u8) !Config {
    const content = try read_config_bytes(allocator, io, file_name);
    defer allocator.free(content);

    return parse_config_text(allocator, content);
}

fn parse_config_text(allocator: std.mem.Allocator, content: []const u8) !Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Split line into key and value
        var parts = std.mem.tokenizeAny(u8, trimmed, " \t");
        const key = parts.next() orelse continue;
        const value = parts.rest();

        try parse_config_line(&config, allocator, key, value);
    }

    return config;
}

/// Config files quote string values (`logfile ""`, `dir "/tmp/x"`); the quotes
/// are syntax, not part of the value.
fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parse_config_line(config: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const trimmed_value = unquote(std.mem.trim(u8, value, " \t\r"));

    // Network
    if (eql(u8, key, "bind")) {
        // Valkey accepts an address list (`bind 127.0.0.1 -::1`) where a `-`
        // prefix marks an address as optional. The server listens on one.
        var addresses = std.mem.tokenizeAny(u8, trimmed_value, " \t");
        if (addresses.next()) |address| {
            const addr = if (address.len > 0 and address[0] == '-') address[1..] else address;
            if (addr.len > 0) config.bind = try allocator.dupe(u8, addr);
        }
    } else if (eql(u8, key, "protected-mode")) {
        config.protected_mode = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "port")) {
        config.port = try parseInt(u16, trimmed_value, 10);
    } else if (eql(u8, key, "tcp-backlog")) {
        config.tcp_backlog = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "timeout")) {
        config.timeout = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "tcp-keepalive")) {
        config.tcp_keepalive = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "maxmemory-samples")) {
        config.maxmemory_samples = try parseInt(u32, trimmed_value, 10);
    }
    // General
    else if (eql(u8, key, "daemonize")) {
        config.daemonize = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "pidfile")) {
        config.pidfile = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "loglevel")) {
        config.loglevel = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "logfile")) {
        config.logfile = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "clock-update-ms")) {
        config.clock_update_ms = try parseInt(u32, trimmed_value, 10);
    }
    // Snapshotting
    else if (eql(u8, key, "stop-writes-on-bgsave-error")) {
        config.stop_writes_on_bgsave_error = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "rdbcompression")) {
        config.rdbcompression = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "rdbchecksum")) {
        config.rdbchecksum = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "dbfilename")) {
        config.dbfilename = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "dir")) {
        config.dir = try allocator.dupe(u8, trimmed_value);
    }
    // Replication
    else if (eql(u8, key, "replica-serve-stale-data")) {
        config.replica_serve_stale_data = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "replica-read-only")) {
        config.replica_read_only = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "repl-diskless-sync")) {
        config.repl_diskless_sync = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "repl-diskless-sync-delay")) {
        config.repl_diskless_sync_delay = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "repl-diskless-load")) {
        config.repl_diskless_load = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "repl-diskless-sync-max-replicas")) {
        config.repl_diskless_sync_max_replicas = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "repl-disable-tcp-nodelay")) {
        config.repl_disable_tcp_nodelay = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "replica-priority")) {
        config.replica_priority = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "rdb-del-sync-files")) {
        config.rdb_del_sync_files = eql(u8, trimmed_value, "yes");
    }
    // Security
    else if (eql(u8, key, "acllog-max-len")) {
        config.acllog_max_len = try parseInt(u32, trimmed_value, 10);
    }
    // Lazy freeing
    else if (eql(u8, key, "lazyfree-lazy-eviction")) {
        config.lazyfree_lazy_eviction = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "lazyfree-lazy-expire")) {
        config.lazyfree_lazy_expire = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "lazyfree-lazy-server-del")) {
        config.lazyfree_lazy_server_del = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "replica-lazy-flush")) {
        config.replica_lazy_flush = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "lazyfree-lazy-user-del")) {
        config.lazyfree_lazy_user_del = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "lazyfree-lazy-user-flush")) {
        config.lazyfree_lazy_user_flush = eql(u8, trimmed_value, "yes");
    }
    // OOM handling
    else if (eql(u8, key, "oom-score-adj")) {
        config.oom_score_adj = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "disable-thp")) {
        config.disable_thp = eql(u8, trimmed_value, "yes");
    }
    // Append only mode
    else if (eql(u8, key, "appendonly")) {
        config.appendonly = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "appendfilename")) {
        config.appendfilename = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "appendfsync")) {
        config.appendfsync = try allocator.dupe(u8, trimmed_value);
    }
    // Memory and performance configuration
    else if (eql(u8, key, "max-clients") or eql(u8, key, "maxclients")) {
        config.max_clients = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "max-channels")) {
        config.max_channels = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "max-subscribers-per-channel")) {
        config.max_subscribers_per_channel = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "kv-memory-budget") or eql(u8, key, "maxmemory")) {
        config.kv_memory_budget = try parse_memory_size(trimmed_value);
        config.kv_memory_budget_explicit = true;
    } else if (eql(u8, key, "initial-capacity")) {
        config.initial_capacity = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "eviction-policy") or eql(u8, key, "maxmemory-policy")) {
        if (eql(u8, trimmed_value, "noeviction")) {
            config.eviction_policy = .noeviction;
        } else if (eql(u8, trimmed_value, "allkeys-lru")) {
            config.eviction_policy = .allkeys_lru;
        } else if (eql(u8, trimmed_value, "volatile-lru")) {
            config.eviction_policy = .volatile_lru;
        } else {
            // Refuse to start rather than silently running a different policy
            // than the one requested (e.g. allkeys-lfu would become LRU).
            return error.InvalidEvictionPolicy;
        }
    } else if (eql(u8, key, "requirepass")) {
        // Valkey treats an empty value as "no password" (EMPTY_STRING_IS_NULL).
        config.requirepass = if (trimmed_value.len == 0) null else try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "rdb-write-buffer-size")) {
        config.rdb_write_buffer_size = try parse_memory_size(trimmed_value);
    } else if (eql(u8, key, "appenddirname")) {
        config.appenddirname = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "no-appendfsync-on-rewrite")) {
        config.no_appendfsync_on_rewrite = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "auto-aof-rewrite-percentage")) {
        config.auto_aof_rewrite_percentage = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "auto-aof-rewrite-min-size")) {
        config.auto_aof_rewrite_min_size = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "aof-load-truncated")) {
        config.aof_load_truncated = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "aof-load-broken")) {
        config.aof_load_broken = eql(u8, trimmed_value, "yes");
    } else if (eql(u8, key, "aof-load-broken-max-size")) {
        config.aof_load_broken_max_size = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "aof-use-rdb-preamble")) {
        config.aof_use_rdb_preamble = eql(u8, trimmed_value, "yes");
    }
}

// Helper function to parse memory sizes like "1gb", "512mb", "1g", "64M", "4096"
pub fn parse_memory_size(value: []const u8) !usize {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return error.InvalidMemorySize;

    var digits = trimmed;
    const has_byte_suffix = digits.len > 1 and std.ascii.toLower(digits[digits.len - 1]) == 'b';
    if (has_byte_suffix) digits = digits[0 .. digits.len - 1];

    var multiplier: usize = 1;
    if (digits.len > 0) switch (std.ascii.toLower(digits[digits.len - 1])) {
        'k', 'm', 'g' => |unit| {
            // Valkey semantics: "1g"/"1m"/"1k" are decimal, "1gb"/"1mb"/"1kb"
            // are binary.
            const decimal: usize = switch (unit) {
                'k' => 1000,
                'm' => 1000 * 1000,
                'g' => 1000 * 1000 * 1000,
                else => unreachable,
            };
            const binary: usize = switch (unit) {
                'k' => 1024,
                'm' => 1024 * 1024,
                'g' => 1024 * 1024 * 1024,
                else => unreachable,
            };
            digits = digits[0 .. digits.len - 1];
            multiplier = if (has_byte_suffix) binary else decimal;
        },
        else => {},
    };

    const num = try parseInt(usize, digits, 10);
    return std.math.mul(usize, num, multiplier);
}

/// Smallest KV budget auto-sizing will pick, even when fixed overhead already
/// exceeds the limit.
const min_kv_budget: usize = 64 * 1024 * 1024;

/// Fixed KV budget used outside containers, where there is no cgroup limit to
/// derive one from.
pub const host_kv_budget: usize = 256 * 1024 * 1024;

const MemoryLimit = union(enum) {
    /// A finite cgroup memory limit applies (container).
    container: u64,
    /// No container limit: use the fixed default budget.
    host,
    /// Detection failed; guessing here either overruns a small container
    /// (SIGKILL instead of -OOM) or throttles a large host.
    unknown,
};

fn resolve_memory_budget(config: *Config, limit: MemoryLimit) !void {
    if (config.kv_memory_budget_explicit) return;

    switch (limit) {
        .container => |bytes| {
            config.kv_memory_budget = budget_from_limit(bytes, config.fixed_memory_size());
            config.memory_budget_source = .container;
        },
        .host => {
            config.kv_memory_budget = host_kv_budget;
            config.memory_budget_source = .default;
        },
        .unknown => return error.UnknownMemoryLimit,
    }
}

fn budget_from_limit(limit: u64, fixed: usize) usize {
    // Keep 20% of the limit for non-budgeted growth: allocator fragmentation,
    // per-client parse arenas, response buffers and the AOF queue.
    const usable = limit / 5 * 4;
    const fixed_bytes: u64 = @intCast(fixed);
    const kv_budget = if (usable > fixed_bytes) usable - fixed_bytes else 0;
    return @intCast(@max(kv_budget, @as(u64, min_kv_budget)));
}

fn detect_memory_limit(allocator: std.mem.Allocator, io: std.Io) MemoryLimit {
    // Containers are a Linux phenomenon; elsewhere there is no cgroup limit
    // to discover.
    if (builtin.target.os.tag != .linux) return .host;

    const proc_cgroup = Dir.cwd().readFileAlloc(io, "/proc/self/cgroup", allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .host,
        else => return .unknown,
    };
    defer allocator.free(proc_cgroup);

    var limit: ?u64 = null;
    var read_any = false;
    var lines = std.mem.splitScalar(u8, proc_cgroup, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Format: "<hierarchy>:<controllers>:<path>" (v1) or "0::<path>" (v2).
        var parts = std.mem.splitScalar(u8, trimmed, ':');
        const hierarchy = parts.next() orelse continue;
        const controllers = parts.next() orelse continue;
        const path = parts.next() orelse continue;

        var base: []const u8 = undefined;
        var file: []const u8 = undefined;
        if (eql(u8, hierarchy, "0") and controllers.len == 0) {
            base = "/sys/fs/cgroup";
            file = "memory.max";
        } else if (has_controller(controllers, "memory")) {
            base = "/sys/fs/cgroup/memory";
            file = "memory.limit_in_bytes";
        } else continue;

        const found = read_cgroup_limit(allocator, io, base, path, file);
        if (found.read_any) read_any = true;
        if (found.limit) |bytes| {
            limit = if (limit) |current| @min(current, bytes) else bytes;
        }
    }

    if (limit) |bytes| return .{ .container = bytes };
    // A readable "max"/v1 sentinel means the host simply has no limit. If no
    // limit file could be read at all, detection is broken, not unlimited.
    return if (read_any) .host else .unknown;
}

fn has_controller(controllers: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, controllers, ',');
    while (it.next()) |controller| {
        if (eql(u8, controller, name)) return true;
    }
    return false;
}

const CgroupRead = struct {
    limit: ?u64 = null,
    /// False when no limit file could be read at any level.
    read_any: bool = false,
};

/// Reads the limit file for `path` and each of its ancestors, keeping the
/// smallest limit found. Missing files and "unlimited" markers are skipped.
fn read_cgroup_limit(allocator: std.mem.Allocator, io: std.Io, base: []const u8, path: []const u8, file: []const u8) CgroupRead {
    var result: CgroupRead = .{};
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var end = path.len;

    while (true) {
        while (end > 0 and path[end - 1] == '/') end -= 1;

        const full = std.fmt.bufPrint(&buffer, "{s}{s}/{s}", .{ base, path[0..end], file }) catch return result;
        if (read_cgroup_limit_file(allocator, io, full)) |value| {
            result.read_any = true;
            if (value) |bytes| {
                result.limit = if (result.limit) |current| @min(current, bytes) else bytes;
            }
        } else |_| {}

        const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/') orelse break;
        end = slash;
    }

    return result;
}

fn read_cgroup_limit_file(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?u64 {
    const text = try Dir.cwd().readFileAlloc(io, path, allocator, .limited(64));
    defer allocator.free(text);
    return parse_cgroup_limit(text);
}

fn parse_cgroup_limit(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or eql(u8, trimmed, "max")) return null;

    const limit = parseInt(u64, trimmed, 10) catch return null;
    // cgroup v1 reports "unlimited" as a value near 2^63.
    if (limit >= 1 << 60) return null;
    return limit;
}

const testing = std.testing;

test "config directives past the first 8 KiB are loaded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var text: std.ArrayList(u8) = .empty;
    for (0..1024) |_| try text.appendSlice(allocator, "# padding padding padding padding\n");
    try text.appendSlice(allocator, "port 7000\n");
    try testing.expect(text.items.len > 8192);

    const path = "zedis_test_config_large.conf";
    try Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = text.items });
    defer Dir.cwd().deleteFile(testing.io, path) catch {};

    const config = try read_file(allocator, testing.io, path);
    try testing.expectEqual(7000, config.port);
}

test "bind takes the first address and drops the optional marker" {
    const cases = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "bind 127.0.0.1 -::1\n", .expected = "127.0.0.1" },
        .{ .text = "bind -::1\n", .expected = "::1" },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const config = try parse_config_text(arena.allocator(), case.text);
        try testing.expectEqualStrings(case.expected, config.bind);
    }
}

test "quoted values lose their quotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const config = try parse_config_text(arena.allocator(), "dbfilename \"custom.rdb\"\nlogfile \"\"\n");
    try testing.expectEqualStrings("custom.rdb", config.dbfilename);
    try testing.expectEqualStrings("", config.logfile);
}

test "empty requirepass disables authentication" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const config = try parse_config_text(arena.allocator(), "requirepass \"\"\n");
    try testing.expect(config.requirepass == null);
    try testing.expect(!config.requires_auth());
}

test "unsupported maxmemory-policy is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(
        error.InvalidEvictionPolicy,
        parse_config_text(arena.allocator(), "maxmemory-policy allkeys-lfu\n"),
    );
}

test "clock-update-ms is settable from the config file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const config = try parse_config_text(arena.allocator(), "clock-update-ms 0\n");
    try testing.expectEqual(0, config.clock_update_ms);
}

test "memory sizes accept single-letter and byte suffixes" {
    try testing.expectEqual(1000 * 1000 * 1000, try parse_memory_size("1g"));
    try testing.expectEqual(64 * 1024 * 1024, try parse_memory_size("64MB"));
    try testing.expectEqual(512 * 1000, try parse_memory_size("512k"));
    try testing.expectEqual(4096, try parse_memory_size("4096"));
}

test "cgroup limits ignore the unlimited marker" {
    try testing.expectEqual(@as(?u64, 2 * 1024 * 1024 * 1024), parse_cgroup_limit("2147483648\n"));
    try testing.expectEqual(@as(?u64, null), parse_cgroup_limit("max\n"));
    try testing.expectEqual(@as(?u64, null), parse_cgroup_limit("9223372036854771712\n"));
}

test "cgroup limit uses the most restrictive ancestor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = "zedis_test_cgroup";
    Dir.cwd().deleteTree(testing.io, root) catch {};
    defer Dir.cwd().deleteTree(testing.io, root) catch {};

    try Dir.cwd().createDirPath(testing.io, root ++ "/docker/abc");
    try Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/memory.max", .data = "max\n" });
    try Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/docker/memory.max", .data = "1073741824\n" });
    try Dir.cwd().writeFile(testing.io, .{ .sub_path = root ++ "/docker/abc/memory.max", .data = "2147483648\n" });

    const found = read_cgroup_limit(allocator, testing.io, root, "/docker/abc", "memory.max");
    try testing.expect(found.read_any);
    try testing.expectEqual(@as(?u64, 1024 * 1024 * 1024), found.limit);
}

test "auto budget keeps 20 percent headroom and excludes fixed memory" {
    const limit: u64 = 8 * 1024 * 1024 * 1024;
    const fixed: usize = 80 * 1024 * 1024;
    try testing.expectEqual(limit / 5 * 4 - fixed, budget_from_limit(limit, fixed));
}

test "auto budget has a floor" {
    try testing.expectEqual(min_kv_budget, budget_from_limit(100 * 1024 * 1024, 80 * 1024 * 1024));
}

test "container limit sizes the budget" {
    var config: Config = .{};
    try resolve_memory_budget(&config, .{ .container = 8 * 1024 * 1024 * 1024 });

    try testing.expectEqual(budget_from_limit(8 * 1024 * 1024 * 1024, config.fixed_memory_size()), config.kv_memory_budget);
    try testing.expectEqual(MemoryBudgetSource.container, config.memory_budget_source);
}

test "host without a container limit uses the fixed budget" {
    var config: Config = .{};
    try resolve_memory_budget(&config, .host);

    try testing.expectEqual(host_kv_budget, config.kv_memory_budget);
    try testing.expectEqual(MemoryBudgetSource.default, config.memory_budget_source);
}

test "explicit maxmemory skips auto sizing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var config = try parse_config_text(arena.allocator(), "maxmemory 100mb\n");
    try resolve_memory_budget(&config, .unknown);

    try testing.expectEqual(100 * 1024 * 1024, config.kv_memory_budget);
    try testing.expectEqual(MemoryBudgetSource.configured, config.memory_budget_source);
}

test "auto sizing fails when the memory limit is unknown" {
    var config: Config = .{};
    try testing.expectError(error.UnknownMemoryLimit, resolve_memory_budget(&config, .unknown));
}

test "stock redis.conf parses as a config file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const config = try read_file(arena.allocator(), testing.io, "tests/fixtures/redis.conf");

    try testing.expectEqual(6379, config.port);
    try testing.expectEqualStrings("127.0.0.1", config.bind); // multi-arg bind list
    try testing.expectEqualStrings("", config.logfile); // quoted empty value
    try testing.expectEqualStrings("everysec", config.appendfsync);
}

test "shipped config files parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    inline for (.{ "zedis.conf", "docker/zedis.conf", "docker/zedis-distroless.conf" }) |path| {
        const config = try read_file(arena.allocator(), testing.io, path);
        try testing.expectEqual(6379, config.port);
    }
}
