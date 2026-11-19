const std = @import("std");
const Allocator = std.mem.Allocator;
const CommandRegistry = @import("registry.zig").CommandRegistry;
const connection_commands = @import("connection.zig");
const string = @import("string.zig");
const list = @import("list.zig");
const hash = @import("hash.zig");
const set = @import("set.zig");
const zset = @import("zset.zig");
const rdb = @import("rdb.zig");
const pubsub = @import("pubsub.zig");
const ts = @import("time_series.zig");
const key = @import("keys.zig");
const server_commands = @import("server.zig");
const lua_commands = @import("lua.zig");

pub fn init_registry(allocator: Allocator) !CommandRegistry {
    var registry = CommandRegistry.init(allocator);

    try registry.register(.{
        .name = "PING",
        .handler = .{ .default = connection_commands.ping },
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ECHO",
        .handler = .{ .default = connection_commands.echo },
        .min_args = 2,
        .max_args = 2,
        .description = "Echo the given string",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "QUIT",
        .handler = .{ .client_handler = connection_commands.quit },
        .min_args = 1,
        .max_args = 1,
        .description = "Close the connection",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "CONFIG",
        .handler = .{ .client_handler = connection_commands.config },
        .min_args = 2,
        .max_args = null,
        .description = "Get or set server configuration parameters",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SET",
        .handler = .{ .store_handler = string.set_full },
        .min_args = 3,
        .max_args = null,
        .description = "Set string value of a key with optional NX/XX/EX/PX/EXAT/PXAT/GET/KEEPTTL",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "GET",
        .handler = .{ .store_handler = string.get },
        .min_args = 2,
        .max_args = 2,
        .description = "Get string value of a key",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "INCR",
        .handler = .{ .store_handler = string.incr },
        .min_args = 2,
        .max_args = 2,
        .description = "Increment the value of a key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "DECR",
        .handler = .{ .store_handler = string.decr },
        .min_args = 2,
        .max_args = 2,
        .description = "Decrement the value of a key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HELP",
        .handler = .{ .default = connection_commands.help },
        .min_args = 1,
        .max_args = 1,
        .description = "Show help message",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "DEL",
        .handler = .{ .store_handler = string.del },
        .min_args = 2,
        .max_args = null,
        .description = "Delete key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "UNLINK",
        .handler = .{ .store_handler = string.del },
        .min_args = 2,
        .max_args = null,
        .description = "Delete keys without blocking",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "SAVE",
        .handler = .{ .client_handler = rdb.save },
        .min_args = 1,
        .max_args = 1,
        .description = "The SAVE commands performs a synchronous save of the dataset producing a point in time snapshot of all the data inside the Redis instance, in the form of an RDB file.",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "PUBLISH",
        .handler = .{ .client_handler = pubsub.publish },
        .min_args = 3,
        .max_args = 3,
        .description = "Publish message",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SUBSCRIBE",
        .handler = .{ .client_handler = pubsub.subscribe },
        .min_args = 2,
        .max_args = null,
        .description = "Subscribe to channels",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "UNSUBSCRIBE",
        .handler = .{ .client_handler = pubsub.unsubscribe },
        .min_args = 1,
        .max_args = null,
        .description = "Unsubscribe from channels",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "EXPIRE",
        .handler = .{ .store_handler = string.expire },
        .min_args = 3,
        .max_args = null,
        .description = "Expire key",
        // TODO: convert to expireat
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "PEXPIRE",
        .handler = .{ .store_handler = string.pexpire },
        .min_args = 3,
        .max_args = null,
        .description = "Set a key's expiry in milliseconds",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "PEXPIREAT",
        // Same handler as EXPIREAT, which takes milliseconds here. The AOF logs
        // EXPIRE, PEXPIRE, and SETEX TTLs as PEXPIREAT (see Server.log_absolute_ttl).
        .handler = .{ .store_handler = string.expire_at },
        .min_args = 3,
        .max_args = 3,
        .description = "Set a key's expiry as a Unix time in milliseconds",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "EXPIREAT",
        .handler = .{ .store_handler = string.expire_at },
        .min_args = 3,
        .max_args = null,
        .description = "Expire key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "AUTH",
        .handler = .{ .client_handler = connection_commands.auth },
        .min_args = 2,
        .max_args = 2,
        .description = "Authenticate to the server",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HELLO",
        .handler = .{ .client_handler = connection_commands.hello },
        .min_args = 1,
        .max_args = null,
        .description = "Switch the connection's RESP version and describe the server",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "CLIENT",
        .handler = .{ .client_handler = connection_commands.client_cmd },
        .min_args = 2,
        .max_args = null,
        .description = "Manage client connections",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SELECT",
        .handler = .{ .client_handler = connection_commands.select },
        .min_args = 2,
        .max_args = 2,
        .description = "Select the logical database (only 0 is available)",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "MULTI",
        .handler = .{ .client_handler = server_commands.multi },
        .min_args = 1,
        .max_args = 1,
        .description = "Start a transaction",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "EXEC",
        .handler = .{ .client_handler = server_commands.exec },
        .min_args = 1,
        .max_args = 1,
        .description = "Execute all commands queued after MULTI",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "DISCARD",
        .handler = .{ .client_handler = server_commands.discard },
        .min_args = 1,
        .max_args = 1,
        .description = "Discard all commands queued after MULTI",
        .write_to_aof = false,
    });

    // List commands: LPUSH, RPUSH, LPOP, RPOP, LLEN, LRANGE

    try registry.register(.{
        .name = "SADD",
        .handler = .{ .store_handler = set.sadd },
        .min_args = 3,
        .max_args = null,
        .description = "Add one or more members to a set",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "SREM",
        .handler = .{ .store_handler = set.srem },
        .min_args = 3,
        .max_args = null,
        .description = "Remove one or more members from a set",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "SMEMBERS",
        .handler = .{ .store_handler = set.smembers },
        .min_args = 2,
        .max_args = 2,
        .description = "Get all members of a set",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SCARD",
        .handler = .{ .store_handler = set.scard },
        .min_args = 2,
        .max_args = 2,
        .description = "Get the number of members in a set",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SISMEMBER",
        .handler = .{ .store_handler = set.sismember },
        .min_args = 3,
        .max_args = 3,
        .description = "Check whether a value is a member of a set",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SSCAN",
        .handler = .{ .store_handler = set.sscan },
        .min_args = 3,
        .max_args = null,
        .description = "Incrementally iterate set members",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ZADD",
        .handler = .{ .store_handler = zset.zadd },
        .min_args = 4,
        .max_args = null,
        .description = "Add or update members of a sorted set",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "ZINCRBY",
        .handler = .{ .store_handler = zset.zincrby },
        .min_args = 4,
        .max_args = 4,
        .description = "Increment the score of a sorted set member",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "ZREM",
        .handler = .{ .store_handler = zset.zrem },
        .min_args = 3,
        .max_args = null,
        .description = "Remove members from a sorted set",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "ZREMRANGEBYSCORE",
        .handler = .{ .store_handler = zset.zremrangebyscore },
        .min_args = 4,
        .max_args = 4,
        .description = "Remove sorted set members within a score range",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "ZCARD",
        .handler = .{ .store_handler = zset.zcard },
        .min_args = 2,
        .max_args = 2,
        .description = "Get the number of members in a sorted set",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ZSCORE",
        .handler = .{ .store_handler = zset.zscore },
        .min_args = 3,
        .max_args = 3,
        .description = "Get the score of a sorted set member",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ZRANGE",
        .handler = .{ .store_handler = zset.zrange },
        .min_args = 4,
        .max_args = null,
        .description = "Return a range of sorted set members",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ZREVRANGE",
        .handler = .{ .store_handler = zset.zrevrange },
        .min_args = 4,
        .max_args = 5,
        .description = "Return a range of sorted set members, highest score first",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ZRANGEBYSCORE",
        .handler = .{ .store_handler = zset.zrangebyscore },
        .min_args = 4,
        .max_args = null,
        .description = "Return sorted set members within a score range",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "ZREVRANGEBYSCORE",
        .handler = .{ .store_handler = zset.zrevrangebyscore },
        .min_args = 4,
        .max_args = null,
        .description = "Return sorted set members within a score range, highest first",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "BLPOP",
        .handler = .{ .store_handler = list.blpop },
        .min_args = 3,
        .max_args = null,
        .description = "Remove and get the first element of a list, blocking until one exists",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "BRPOP",
        .handler = .{ .store_handler = list.brpop },
        .min_args = 3,
        .max_args = null,
        .description = "Remove and get the last element of a list, blocking until one exists",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "BLMOVE",
        .handler = .{ .store_handler = list.blmove },
        .min_args = 6,
        .max_args = 6,
        .description = "Pop from one list and push to another, blocking until the source has data",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LMOVE",
        .handler = .{ .store_handler = list.lmove },
        .min_args = 5,
        .max_args = 5,
        .description = "Pop an element from one list and push it to another",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "RPOPLPUSH",
        .handler = .{ .store_handler = list.rpoplpush },
        .min_args = 3,
        .max_args = 3,
        .description = "Pop the tail of one list and push it to the head of another",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LPUSH",
        .handler = .{ .store_handler = list.lpush },
        .min_args = 3,
        .max_args = null,
        .description = "Prepend one or multiple values to a list",
        // TODO: test
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "RPUSH",
        .handler = .{ .store_handler = list.rpush },
        .min_args = 3,
        .max_args = null,
        .description = "Append one or multiple values to a list",
        // TODO: test
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LPOP",
        .handler = .{ .store_handler = list.lpop },
        .min_args = 2,
        .max_args = 3,
        .description = "Remove and return the first element of a list",
        // TODO: test
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "RPOP",
        .handler = .{ .store_handler = list.rpop },
        .min_args = 2,
        .max_args = 3,
        .description = "Remove and return the last element of a list",
        // TODO: test
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LLEN",
        .handler = .{ .store_handler = list.llen },
        .min_args = 2,
        .max_args = 2,
        .description = "Get the length of a list",
        // TODO: test
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "LINDEX",
        .handler = .{ .store_handler = list.lindex },
        .min_args = 3,
        .max_args = 3,
        .description = "Get an element from a list by its index",
        // TODO: test
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "LSET",
        .handler = .{ .store_handler = list.lset },
        .min_args = 4,
        .max_args = 4,
        .description = "Set the value of an element in a list by its index",
        // TODO: test
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LRANGE",
        .handler = .{ .store_handler = list.lrange },
        .min_args = 4,
        .max_args = 4,
        .description = "Get a range of elements from a list",
        // TODO: test
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "APPEND",
        .handler = .{ .store_handler = string.append },
        .min_args = 3,
        .max_args = 3,
        .description = "Append a value to a key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "STRLEN",
        .handler = .{ .store_handler = string.strlen },
        .min_args = 2,
        .max_args = 2,
        .description = "Get the length of the value stored in a key",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "GETSET",
        .handler = .{ .store_handler = string.getset },
        .min_args = 3,
        .max_args = 3,
        .description = "Set a key and return its old value",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "MGET",
        .handler = .{ .store_handler = string.mget },
        .min_args = 2,
        .max_args = null,
        .description = "Get the values of multiple keys",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "MSET",
        .handler = .{ .store_handler = string.mset },
        .min_args = 3,
        .max_args = null,
        .description = "Set multiple key-value pairs",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "SETEX",
        .handler = .{ .store_handler = string.setex },
        .min_args = 4,
        .max_args = 4,
        .description = "Set a key with expiration time",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "SETNX",
        .handler = .{ .store_handler = string.setnx },
        .min_args = 3,
        .max_args = 3,
        .description = "Set a key only if it doesn't exist",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "INCRBY",
        .handler = .{ .store_handler = string.incrby },
        .min_args = 3,
        .max_args = 3,
        .description = "Increment a key by a specific amount",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "DECRBY",
        .handler = .{ .store_handler = string.decrby },
        .min_args = 3,
        .max_args = 3,
        .description = "Decrement a key by a specific amount",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "INCRBYFLOAT",
        .handler = .{ .store_handler = string.incrbyfloat },
        .min_args = 3,
        .max_args = 3,
        .description = "Increment a key by a floating point number",
        .write_to_aof = true,
    });

    // Key commands

    try registry.register(.{
        .name = "KEYS",
        .handler = .{ .store_handler = key.keys },
        .min_args = 2,
        .max_args = 2,
        .description = "Find all keys matching a pattern",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "EXISTS",
        .handler = .{ .store_handler = key.exists },
        .min_args = 2,
        .max_args = null,
        .description = "Check if key exists",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "TTL",
        .handler = .{ .store_handler = key.ttl },
        .min_args = 2,
        .max_args = 2,
        .description = "Get remaining time to live of a key",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "PTTL",
        .handler = .{ .store_handler = key.pttl },
        .min_args = 2,
        .max_args = 2,
        .description = "Get remaining time to live of a key in milliseconds",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SCAN",
        .handler = .{ .store_handler = key.scan },
        .min_args = 2,
        .max_args = null,
        .description = "Incrementally iterate over keys",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "PERSIST",
        .handler = .{ .store_handler = key.persist },
        .min_args = 2,
        .max_args = 2,
        .description = "Remove expiration from a key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TYPE",
        .handler = .{ .store_handler = key.type_cmd },
        .min_args = 2,
        .max_args = 2,
        .description = "Get the data type of a key",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "RENAME",
        .handler = .{ .store_handler = key.rename },
        .min_args = 3,
        .max_args = 3,
        .description = "Rename a key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "RANDOMKEY",
        .handler = .{ .store_handler = key.randomkey },
        .min_args = 1,
        .max_args = 1,
        .description = "Return a random key",
        .write_to_aof = false,
    });

    // Time series commands
    try registry.register(.{
        .name = "TS.CREATE",
        .handler = .{ .store_handler = ts.ts_create },
        .min_args = 2,
        .max_args = null,
        .description = "Create a new time series",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TS.ADD",
        .handler = .{ .store_handler = ts.ts_add },
        .min_args = 4,
        .max_args = null,
        .description = "Add a new sample to a time series",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TS.GET",
        .handler = .{ .store_handler = ts.ts_get },
        .min_args = 2,
        .max_args = 2,
        .description = "Get the last sample from a time series",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "TS.INCRBY",
        .handler = .{ .store_handler = ts.ts_incrby },
        .min_args = 4,
        .max_args = 4,
        .description = "Increment the last value and add as a new sample",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TS.DECRBY",
        .handler = .{ .store_handler = ts.ts_decrby },
        .min_args = 4,
        .max_args = 4,
        .description = "Decrement the last value and add as a new sample",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TS.ALTER",
        .handler = .{ .store_handler = ts.ts_alter },
        .min_args = 2,
        .max_args = null,
        .description = "Alter time series properties",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TS.ALTER",
        .handler = .{ .store_handler = ts.ts_alter },
        .min_args = 2,
        .max_args = null,
        .description = "Alter time series properties",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "TS.RANGE",
        .handler = .{ .store_handler = ts.ts_range },
        .min_args = 4,
        .max_args = null,
        .description = "Query a range of samples from a time series",
        .write_to_aof = false,
    });

    // Server commands

    try registry.register(.{
        .name = "INFO",
        .handler = .{ .client_handler = server_commands.info_cmd },
        .min_args = 1,
        .max_args = 2,
        .description = "Get server information and statistics",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "METRICS",
        .handler = .{ .client_handler = server_commands.metrics_cmd },
        .min_args = 1,
        .max_args = 2,
        .description = "Return Prometheus text exposition metrics",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SLOWLOG",
        .handler = .{ .client_handler = server_commands.slowlog_cmd },
        .min_args = 1,
        .max_args = 3,
        .description = "Inspect the slow command log",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "LATENCY",
        .handler = .{ .client_handler = server_commands.latency_cmd },
        .min_args = 1,
        .max_args = null,
        .description = "Inspect latency events",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "BGREWRITEAOF",
        .handler = .{ .client_handler = server_commands.bgrewriteaof },
        .min_args = 1,
        .max_args = 1,
        .description = "Rewrite the append-only file as a snapshot of the dataset",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SHUTDOWN",
        .handler = .{ .client_handler = server_commands.shutdown_cmd },
        .min_args = 1,
        .max_args = 2,
        .description = "Stop the server, flushing the AOF",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "COMMAND",
        .handler = .{ .client_handler = server_commands.command_cmd },
        .min_args = 1,
        .max_args = null,
        .description = "Get information about available commands",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "DBSIZE",
        .handler = .{ .store_handler = server_commands.db_size },
        .min_args = 1,
        .max_args = 1,
        .description = "Get database size",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "FLUSHDB",
        .handler = .{ .client_handler = server_commands.flush_db },
        .min_args = 1,
        .max_args = 1,
        .description = "Flush the store",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "FLUSHALL",
        .handler = .{ .client_handler = server_commands.flush_all },
        .min_args = 1,
        .max_args = 1,
        .description = "Flush the store",
        .write_to_aof = true,
    });

    // Bloom Filter Commands
    const bloom = @import("bloom.zig");

    try registry.register(.{
        .name = "BF.RESERVE",
        .handler = .{ .store_handler = bloom.bf_reserve },
        .min_args = 4,
        .max_args = null,
        .description = "Create a new Bloom filter with specified parameters",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "BF.ADD",
        .handler = .{ .store_handler = bloom.bf_add },
        .min_args = 3,
        .max_args = 3,
        .description = "Add an item to a Bloom filter",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "BF.MADD",
        .handler = .{ .store_handler = bloom.bf_madd },
        .min_args = 3,
        .max_args = null,
        .description = "Add multiple items to a Bloom filter",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "BF.EXISTS",
        .handler = .{ .store_handler = bloom.bf_exists },
        .min_args = 3,
        .max_args = 3,
        .description = "Check if an item may exist in a Bloom filter",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "BF.MEXISTS",
        .handler = .{ .store_handler = bloom.bf_mexists },
        .min_args = 3,
        .max_args = null,
        .description = "Check if multiple items may exist in a Bloom filter",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "BF.INFO",
        .handler = .{ .store_handler = bloom.bf_info },
        .min_args = 2,
        .max_args = 2,
        .description = "Get information about a Bloom filter",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "BF.INSERT",
        .handler = .{ .store_handler = bloom.bf_insert },
        .min_args = 3,
        .max_args = null,
        .description = "Add items to a Bloom filter, creating it if it doesn't exist",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HSET",
        .handler = .{ .store_handler = hash.hset },
        .min_args = 4,
        .max_args = null,
        .description = "Set hash field(s)",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HMSET",
        .handler = .{ .store_handler = hash.hmset },
        .min_args = 4,
        .max_args = null,
        .description = "Set multiple hash fields (deprecated alias for HSET)",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HGET",
        .handler = .{ .store_handler = hash.hget },
        .min_args = 3,
        .max_args = 3,
        .description = "Get hash field value",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HMGET",
        .handler = .{ .store_handler = hash.hmget },
        .min_args = 3,
        .max_args = null,
        .description = "Get multiple hash field values",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HGETALL",
        .handler = .{ .store_handler = hash.hgetall },
        .min_args = 2,
        .max_args = 2,
        .description = "Get all hash fields and values",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HDEL",
        .handler = .{ .store_handler = hash.hdel },
        .min_args = 3,
        .max_args = null,
        .description = "Delete hash fields",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HEXISTS",
        .handler = .{ .store_handler = hash.hexists },
        .min_args = 3,
        .max_args = 3,
        .description = "Check if hash field exists",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HKEYS",
        .handler = .{ .store_handler = hash.hkeys },
        .min_args = 2,
        .max_args = 2,
        .description = "Get all hash field names",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HVALS",
        .handler = .{ .store_handler = hash.hvals },
        .min_args = 2,
        .max_args = 2,
        .description = "Get all hash values",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HLEN",
        .handler = .{ .store_handler = hash.hlen },
        .min_args = 2,
        .max_args = 2,
        .description = "Get number of fields in a hash",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "HSCAN",
        .handler = .{ .store_handler = hash.hscan },
        .min_args = 3,
        .max_args = null,
        .description = "Incrementally iterate hash fields and values",
        .write_to_aof = false,
    });

    // --- String commands ---

    try registry.register(.{
        .name = "GETEX",
        .handler = .{ .store_handler = string.getex },
        .min_args = 2,
        .max_args = 4,
        .description = "Get value and optionally set/clear expiry",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "GETDEL",
        .handler = .{ .store_handler = string.getdel },
        .min_args = 2,
        .max_args = 2,
        .description = "Get value and delete the key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "GETRANGE",
        .handler = .{ .store_handler = string.getrange },
        .min_args = 4,
        .max_args = 4,
        .description = "Get a substring of a string value",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SUBSTR",
        .handler = .{ .store_handler = string.getrange },
        .min_args = 4,
        .max_args = 4,
        .description = "Alias for GETRANGE",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "SETRANGE",
        .handler = .{ .store_handler = string.setrange },
        .min_args = 4,
        .max_args = 4,
        .description = "Overwrite part of a string at offset",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "PSETEX",
        .handler = .{ .store_handler = string.psetex },
        .min_args = 4,
        .max_args = 4,
        .description = "Set value with millisecond expiry",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "MSETNX",
        .handler = .{ .store_handler = string.msetnx },
        .min_args = 3,
        .max_args = null,
        .description = "Set multiple keys only if none exist",
        .write_to_aof = true,
    });

    // --- List commands ---

    try registry.register(.{
        .name = "LREM",
        .handler = .{ .store_handler = list.lrem },
        .min_args = 4,
        .max_args = 4,
        .description = "Remove elements from a list",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LTRIM",
        .handler = .{ .store_handler = list.ltrim },
        .min_args = 4,
        .max_args = 4,
        .description = "Trim a list to a range",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "LINSERT",
        .handler = .{ .store_handler = list.linsert },
        .min_args = 5,
        .max_args = 5,
        .description = "Insert element before or after pivot",
        .write_to_aof = true,
    });

    // --- Hash commands ---

    try registry.register(.{
        .name = "HSETNX",
        .handler = .{ .store_handler = hash.hsetnx },
        .min_args = 4,
        .max_args = 4,
        .description = "Set hash field only if it does not exist",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HINCRBY",
        .handler = .{ .store_handler = hash.hincrby },
        .min_args = 4,
        .max_args = 4,
        .description = "Increment hash field by integer",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "HINCRBYFLOAT",
        .handler = .{ .store_handler = hash.hincrbyfloat },
        .min_args = 4,
        .max_args = 4,
        .description = "Increment hash field by float",
        .write_to_aof = true,
    });

    // --- Key commands ---

    try registry.register(.{
        .name = "EXPIRETIME",
        .handler = .{ .store_handler = key.expiretime },
        .min_args = 2,
        .max_args = 2,
        .description = "Get expiry as Unix timestamp (seconds)",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "PEXPIRETIME",
        .handler = .{ .store_handler = key.pexpiretime },
        .min_args = 2,
        .max_args = 2,
        .description = "Get expiry as Unix timestamp (milliseconds)",
        .write_to_aof = false,
    });

    try registry.register(.{
        .name = "COPY",
        .handler = .{ .store_handler = key.copy },
        .min_args = 3,
        .max_args = 4,
        .description = "Copy a key to a destination key",
        .write_to_aof = true,
    });

    try registry.register(.{
        .name = "OBJECT",
        .handler = .{ .store_handler = key.object_cmd },
        .min_args = 2,
        .max_args = null,
        .description = "Object inspection subcommands (ENCODING, REFCOUNT, IDLETIME, FREQ, HELP)",
        .write_to_aof = false,
    });

    // --- Connection commands ---

    try registry.register(.{
        .name = "RESET",
        .handler = .{ .client_handler = connection_commands.reset },
        .min_args = 1,
        .max_args = 1,
        .description = "Reset connection state",
        .write_to_aof = false,
    });

    // --- Lua scripting commands ---

    try registry.register(.{
        .name = "EVAL",
        .handler = .{ .client_handler = lua_commands.eval },
        .min_args = 3,
        .max_args = null,
        .description = "Execute a Lua script server-side",
        .write_to_aof = false,
        .denyoom = true,
    });

    try registry.register(.{
        .name = "EVALSHA",
        .handler = .{ .client_handler = lua_commands.evalsha },
        .min_args = 3,
        .max_args = null,
        .description = "Execute a cached Lua script by SHA1",
        .write_to_aof = false,
        .denyoom = true,
    });

    try registry.register(.{
        .name = "SCRIPT",
        .handler = .{ .client_handler = lua_commands.script_cmd },
        .min_args = 2,
        .max_args = null,
        .description = "Script management: LOAD, EXISTS, FLUSH",
        .write_to_aof = false,
    });

    // Redis' CMD_DENYOOM: commands that may allocate store memory and are
    // rejected with -OOM when the budget is exhausted. Commands that only free
    // memory (DEL, LPOP, RPOP, FLUSHDB, ...) and commands that don't touch the
    // store stay allowed, so a full instance can still be drained.
    const denyoom_commands = [_][]const u8{
        "SET",          "INCR",   "DECR",      "APPEND",    "GETSET",
        "MSET",         "SETEX",  "SETNX",     "INCRBY",    "DECRBY",
        "INCRBYFLOAT",  "RENAME", "LPUSH",     "RPUSH",     "LSET",
        "TS.CREATE",    "TS.ADD", "TS.INCRBY", "TS.DECRBY", "TS.ALTER",
        "BF.RESERVE",   "BF.ADD", "BF.MADD",   "BF.INSERT", "HSET",
        "HMSET",        "GETEX",  "SETRANGE",  "PSETEX",    "MSETNX",
        "LINSERT",      "LMOVE",  "RPOPLPUSH", "HSETNX",    "HINCRBY",
        "HINCRBYFLOAT", "COPY",   "BLMOVE",    "SADD",      "ZADD",
        "ZINCRBY",
    };
    for (denyoom_commands) |name| {
        const info = registry.commands.getPtr(name) orelse {
            std.debug.assert(false);
            continue;
        };
        info.denyoom = true;
    }

    return registry;
}
