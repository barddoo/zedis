const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;
const Client = @import("./client.zig").Client;
const ClientHandle = @import("./types.zig").ClientHandle;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;

const Config = @This();

pub const EvictionPolicy = enum {
    noeviction, // Return errors when memory limit reached
    allkeys_lru, // Evict least recently used keys
    volatile_lru, // Evict LRU keys with expire set
};

pub const MemoryStats = struct {
    fixed_memory_used: usize,
    kv_memory_used: usize,
    temp_arena_used: usize,
    total_allocated: usize,
    total_budget: usize,

    pub fn usagePercent(self: MemoryStats) u8 {
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
kv_memory_budget: usize = 2 * 1024 * 1024 * 1024, // 2GB for key-value store (production headroom)
temp_arena_size: usize = 512 * 1024 * 1024, // 512MB for temporary allocations
initial_capacity: u32 = 8192, // Initial hash map capacity for Store (reduces early rehashing)
eviction_policy: EvictionPolicy = .allkeys_lru, // LRU eviction policy
requirepass: ?[]const u8 = null, // Password authentication (null = disabled)
rdb_write_buffer_size: usize = 256 * 1024, // 256KB buffer for RDB writes (optimal SSD throughput)
aof_write_buffer_size: usize = 64 * 1024, // 64KB buffer for AOF writes

// Computed constants (calculated from other fields)
pub fn clientPoolSize(self: Config) usize {
    return self.max_clients * @sizeOf(Client);
}

pub fn pubsubMatrixSize(self: Config) usize {
    return self.max_channels * self.max_subscribers_per_channel * @sizeOf(ClientHandle);
}

pub fn fixedMemorySize(self: Config) usize {
    return self.clientPoolSize() + self.pubsubMatrixSize();
}

pub fn totalMemoryBudget(self: Config) usize {
    return self.fixedMemorySize() + self.kv_memory_budget + self.temp_arena_size;
}

pub fn requiresAuth(self: Config) bool {
    return self.requirepass != null;
}

pub fn readConfig(allocator: std.mem.Allocator, io: std.Io, args: std.process.Args) !Config {
    var args_iter = if (builtin.os.tag == .windows) args.iterate() else try std.process.Args.Iterator.initAllocator(args, allocator);

    _ = args_iter.skip();

    if (args_iter.next()) |file_name| {
        return try readFile(allocator, io, file_name);
    }

    // Return default config
    return .{};
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_name: []const u8) !Config {
    var file = try Dir.cwd().openFile(io, file_name, .{});
    defer file.close(io);

    var buffer: [1024 * 8]u8 = undefined;
    const n = try file.readPositionalAll(io, &buffer, 0);
    const content = buffer[0..n];

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

        try parseConfigLine(&config, allocator, key, value);
    }

    return config;
}

fn parseConfigLine(config: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const trimmed_value = std.mem.trim(u8, value, " \t\r");

    // Network
    if (eql(u8, key, "bind")) {
        config.bind = try allocator.dupe(u8, trimmed_value);
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
    } else if (eql(u8, key, "kv-memory-budget")) {
        config.kv_memory_budget = try parseMemorySize(trimmed_value);
    } else if (eql(u8, key, "temp-arena-size")) {
        config.temp_arena_size = try parseMemorySize(trimmed_value);
    } else if (eql(u8, key, "initial-capacity")) {
        config.initial_capacity = try parseInt(u32, trimmed_value, 10);
    } else if (eql(u8, key, "eviction-policy") or eql(u8, key, "maxmemory-policy")) {
        if (eql(u8, trimmed_value, "noeviction")) {
            config.eviction_policy = .noeviction;
        } else if (eql(u8, trimmed_value, "allkeys-lru")) {
            config.eviction_policy = .allkeys_lru;
        } else if (eql(u8, trimmed_value, "volatile-lru")) {
            config.eviction_policy = .volatile_lru;
        }
    } else if (eql(u8, key, "requirepass")) {
        config.requirepass = try allocator.dupe(u8, trimmed_value);
    } else if (eql(u8, key, "rdb-write-buffer-size")) {
        config.rdb_write_buffer_size = try parseMemorySize(trimmed_value);
    } else if (eql(u8, key, "aof-write-buffer-size")) {
        config.aof_write_buffer_size = try parseMemorySize(trimmed_value);
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

// Helper function to parse memory sizes like "1gb", "512mb", "4096"
pub fn parseMemorySize(value: []const u8) !usize {
    const lower = try std.ascii.allocLowerString(std.heap.page_allocator, value);
    defer std.heap.page_allocator.free(lower);

    if (std.mem.endsWith(u8, lower, "gb")) {
        const num_str = lower[0 .. lower.len - 2];
        const num = try parseInt(usize, num_str, 10);
        return num * 1024 * 1024 * 1024;
    } else if (std.mem.endsWith(u8, lower, "mb")) {
        const num_str = lower[0 .. lower.len - 2];
        const num = try parseInt(usize, num_str, 10);
        return num * 1024 * 1024;
    } else if (std.mem.endsWith(u8, lower, "kb")) {
        const num_str = lower[0 .. lower.len - 2];
        const num = try parseInt(usize, num_str, 10);
        return num * 1024;
    } else {
        // Plain number in bytes
        return try parseInt(usize, value, 10);
    }
}
