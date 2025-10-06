const std = @import("std");

const Self = @This();

const Config = struct {
    // Network
    /// Bind to specific network interfaces. Default: "127.0.0.1 -::1"
    bind: []const u8 = "127.0.0.1 -::1",
    /// Enable protected mode for security when no password is set. Default: yes
    protected_mode: bool = true,
    /// TCP port to listen on. Default: 6379
    port: u16 = 6379,
    /// TCP listen backlog. Default: 511
    tcp_backlog: u32 = 511,
    /// Close connection after client is idle for N seconds (0 to disable). Default: 0
    timeout: u32 = 0,
    /// TCP keepalive interval in seconds. Default: 300
    tcp_keepalive: u32 = 300,

    // General
    /// Run as a daemon process. Default: no
    daemonize: bool = false,
    /// PID file location when daemonized. Default: "/var/run/redis_6379.pid"
    pidfile: []const u8 = "/var/run/redis_6379.pid",
    /// Log verbosity level (debug, verbose, notice, warning). Default: "notice"
    loglevel: []const u8 = "notice",
    /// Log file path (empty string for stdout). Default: ""
    logfile: []const u8 = "",
    /// Number of databases. Default: 16
    databases: u32 = 16,
    /// Show Redis logo on startup. Default: no
    always_show_logo: bool = false,
    /// Set process title visible in ps/top. Default: yes
    set_proc_title: bool = true,
    /// Template for process title. Default: "{title} {listen-addr} {server-mode}"
    proc_title_template: []const u8 = "{title} {listen-addr} {server-mode}",
    /// Locale collation setting. Default: ""
    locale_collate: []const u8 = "",

    // Snapshotting
    /// Stop accepting writes if RDB snapshot fails. Default: yes
    stop_writes_on_bgsave_error: bool = true,
    /// Compress RDB snapshot files with LZF. Default: yes
    rdbcompression: bool = true,
    /// Add CRC64 checksum to RDB files. Default: yes
    rdbchecksum: bool = true,
    /// Filename for RDB snapshot. Default: "dump.rdb"
    dbfilename: []const u8 = "dump.rdb",
    /// Delete sync files used for replication. Default: no
    rdb_del_sync_files: bool = false,
    /// Working directory for RDB/AOF files. Default: "./"
    dir: []const u8 = "./",

    // Replication
    /// Serve stale data when replica loses connection to master. Default: yes
    replica_serve_stale_data: bool = true,
    /// Make replicas read-only. Default: yes
    replica_read_only: bool = true,
    /// Use diskless replication (transfer RDB via socket). Default: yes
    repl_diskless_sync: bool = true,
    /// Delay before diskless sync starts (seconds). Default: 5
    repl_diskless_sync_delay: u32 = 5,
    /// Max replicas to sync in parallel (0 = unlimited). Default: 0
    repl_diskless_sync_max_replicas: u32 = 0,
    /// How replicas load RDB (disabled, on-empty-db, swapdb). Default: "disabled"
    repl_diskless_load: []const u8 = "disabled",
    /// Disable TCP_NODELAY on replica socket. Default: no
    repl_disable_tcp_nodelay: bool = false,
    /// Priority for replica promotion (lower = higher priority). Default: 100
    replica_priority: u32 = 100,

    // Security
    /// Maximum length of ACL log. Default: 128
    acllog_max_len: u32 = 128,

    // Lazy freeing
    /// Async free memory for evicted keys. Default: no
    lazyfree_lazy_eviction: bool = false,
    /// Async free memory for expired keys. Default: no
    lazyfree_lazy_expire: bool = false,
    /// Async free memory for deleted keys (DEL, RENAME, etc). Default: no
    lazyfree_lazy_server_del: bool = false,
    /// Async flush replica's database during full resync. Default: no
    replica_lazy_flush: bool = false,
    /// Async free memory for user-called DEL commands. Default: no
    lazyfree_lazy_user_del: bool = false,
    /// Async free memory for FLUSHDB/FLUSHALL commands. Default: no
    lazyfree_lazy_user_flush: bool = false,

    // OOM handling
    /// Adjust OOM killer score. Default: no
    oom_score_adj: bool = false,
    /// OOM score values for different states. Default: [0, 200, 800]
    oom_score_adj_values: []const u32 = &[_]u32{ 0, 200, 800 },
    /// Disable Transparent Huge Pages. Default: yes
    disable_thp: bool = true,

    // Append only mode
    /// Enable AOF persistence mode. Default: no
    appendonly: bool = false,
    /// AOF filename. Default: "appendonly.aof"
    appendfilename: []const u8 = "appendonly.aof",
    /// Directory for AOF files. Default: "appendonlydir"
    appenddirname: []const u8 = "appendonlydir",
    /// AOF fsync policy (always, everysec, no). Default: "everysec"
    appendfsync: []const u8 = "everysec",
    /// Disable fsync during BGSAVE or BGREWRITEAOF. Default: no
    no_appendfsync_on_rewrite: bool = false,
    /// Trigger AOF rewrite when size grows by this percentage. Default: 100
    auto_aof_rewrite_percentage: u32 = 100,
    /// Minimum AOF size to trigger auto rewrite. Default: "64mb"
    auto_aof_rewrite_min_size: []const u8 = "64mb",
    /// Load truncated AOF file on startup. Default: yes
    aof_load_truncated: bool = true,
    /// Allow loading corrupted AOF with warnings. Default: no
    aof_load_broken: bool = false,
    /// Max size of broken AOF file to load (bytes). Default: 4096
    aof_load_broken_max_size: u32 = 4096,
    /// Use RDB preamble in AOF for faster restarts. Default: yes
    aof_use_rdb_preamble: bool = true,

    // Legacy fields
    max_clients: usize = 10000,
    timeout_seconds: u64 = 0,
    host: []const u8 = "127.0.0.1",
};

pub fn readConfig(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // If config file path is provided as argument, read it
    if (args.len > 1) {
        return try readFile(allocator, args[1]);
    }

    // Return default config
    return .{};
}

fn readFile(allocator: std.mem.Allocator, file_name: []const u8) !Config {
    var file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
    defer file.close();

    var buffer: [8192]u8 = undefined;
    var file_reader = file.reader(&buffer);
    var reader = &file_reader.interface;

    var config = Config{};

    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

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
    if (std.mem.eql(u8, key, "bind")) {
        config.bind = try allocator.dupe(u8, trimmed_value);
    } else if (std.mem.eql(u8, key, "protected-mode")) {
        config.protected_mode = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "port")) {
        config.port = try std.fmt.parseInt(u16, trimmed_value, 10);
    } else if (std.mem.eql(u8, key, "tcp-backlog")) {
        config.tcp_backlog = try std.fmt.parseInt(u32, trimmed_value, 10);
    } else if (std.mem.eql(u8, key, "timeout")) {
        config.timeout = try std.fmt.parseInt(u32, trimmed_value, 10);
    } else if (std.mem.eql(u8, key, "tcp-keepalive")) {
        config.tcp_keepalive = try std.fmt.parseInt(u32, trimmed_value, 10);
    }
    // General
    else if (std.mem.eql(u8, key, "daemonize")) {
        config.daemonize = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "pidfile")) {
        config.pidfile = try allocator.dupe(u8, trimmed_value);
    } else if (std.mem.eql(u8, key, "loglevel")) {
        config.loglevel = try allocator.dupe(u8, trimmed_value);
    } else if (std.mem.eql(u8, key, "logfile")) {
        config.logfile = try allocator.dupe(u8, trimmed_value);
    } else if (std.mem.eql(u8, key, "databases")) {
        config.databases = try std.fmt.parseInt(u32, trimmed_value, 10);
    } else if (std.mem.eql(u8, key, "always-show-logo")) {
        config.always_show_logo = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "set-proc-title")) {
        config.set_proc_title = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "proc-title-template")) {
        config.proc_title_template = try allocator.dupe(u8, trimmed_value);
    }
    // Snapshotting
    else if (std.mem.eql(u8, key, "stop-writes-on-bgsave-error")) {
        config.stop_writes_on_bgsave_error = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "rdbcompression")) {
        config.rdbcompression = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "rdbchecksum")) {
        config.rdbchecksum = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "dbfilename")) {
        config.dbfilename = try allocator.dupe(u8, trimmed_value);
    } else if (std.mem.eql(u8, key, "dir")) {
        config.dir = try allocator.dupe(u8, trimmed_value);
    }
    // Replication
    else if (std.mem.eql(u8, key, "replica-serve-stale-data")) {
        config.replica_serve_stale_data = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "replica-read-only")) {
        config.replica_read_only = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "repl-diskless-sync")) {
        config.repl_diskless_sync = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "repl-diskless-sync-delay")) {
        config.repl_diskless_sync_delay = try std.fmt.parseInt(u32, trimmed_value, 10);
    } else if (std.mem.eql(u8, key, "repl-diskless-load")) {
        config.repl_diskless_load = try allocator.dupe(u8, trimmed_value);
    }
    // Append only mode
    else if (std.mem.eql(u8, key, "appendonly")) {
        config.appendonly = std.mem.eql(u8, trimmed_value, "yes");
    } else if (std.mem.eql(u8, key, "appendfilename")) {
        config.appendfilename = try allocator.dupe(u8, trimmed_value);
    } else if (std.mem.eql(u8, key, "appendfsync")) {
        config.appendfsync = try allocator.dupe(u8, trimmed_value);
    }
    // Add more config options as needed
}
