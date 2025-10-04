const std = @import("std");
const Allocator = std.mem.Allocator;
const CommandRegistry = @import("registry.zig").CommandRegistry;
const connection_commands = @import("connection.zig");
const string = @import("string.zig");
const list = @import("list.zig");
const rdb = @import("../commands/rdb.zig");
const pubsub = @import("../pubsub/pubsub.zig");

pub fn initRegistry(allocator: Allocator) !CommandRegistry {
    var registry = CommandRegistry.init(allocator);

    try registry.register(.{
        .name = "PING",
        .handler = connection_commands.ping,
        .min_args = 1,
        .max_args = 2,
        .description = "Ping the server",
    });

    try registry.register(.{
        .name = "ECHO",
        .handler = connection_commands.echo,
        .min_args = 2,
        .max_args = 2,
        .description = "Echo the given string",
    });

    try registry.register(.{
        .name = "QUIT",
        .handler = connection_commands.quit,
        .min_args = 1,
        .max_args = 1,
        .description = "Close the connection",
    });

    try registry.register(.{
        .name = "SET",
        .handler = string.set,
        .min_args = 3,
        .max_args = 3,
        .description = "Set string value of a key",
    });

    try registry.register(.{
        .name = "GET",
        .handler = string.get,
        .min_args = 2,
        .max_args = 2,
        .description = "Get string value of a key",
    });

    try registry.register(.{
        .name = "INCR",
        .handler = string.incr,
        .min_args = 2,
        .max_args = 2,
        .description = "Increment the value of a key",
    });

    try registry.register(.{
        .name = "DECR",
        .handler = string.decr,
        .min_args = 2,
        .max_args = 2,
        .description = "Decrement the value of a key",
    });

    try registry.register(.{
        .name = "HELP",
        .handler = connection_commands.help,
        .min_args = 1,
        .max_args = 1,
        .description = "Show help message",
    });

    try registry.register(.{
        .name = "DEL",
        .handler = string.del,
        .min_args = 2,
        .max_args = null,
        .description = "Delete key",
    });

    try registry.register(.{
        .name = "SAVE",
        .handler = rdb.save,
        .min_args = 1,
        .max_args = 1,
        .description = "The SAVE commands performs a synchronous save of the dataset producing a point in time snapshot of all the data inside the Redis instance, in the form of an RDB file.",
    });

    try registry.register(.{
        .name = "PUBLISH",
        .handler = pubsub.publish,
        .min_args = 3,
        .max_args = 3,
        .description = "Publish message",
    });

    try registry.register(.{
        .name = "SUBSCRIBE",
        .handler = pubsub.subscribe,
        .min_args = 2,
        .max_args = null,
        .description = "Subscribe to channels",
    });

    try registry.register(.{
        .name = "EXPIRE",
        .handler = string.expire,
        .min_args = 3,
        .max_args = null,
        .description = "Expire key",
    });

    try registry.register(.{
        .name = "AUTH",
        .handler = connection_commands.auth,
        .min_args = 2,
        .max_args = 2,
        .description = "Authenticate to the server",
    });

    // List commands: LPUSH, RPUSH, LPOP, RPOP, LLEN, LRANGE

    try registry.register(.{
        .name = "LPUSH",
        .handler = list.lpush,
        .min_args = 3,
        .max_args = null,
        .description = "Prepend one or multiple values to a list",
    });

    try registry.register(.{
        .name = "RPUSH",
        .handler = list.rpush,
        .min_args = 3,
        .max_args = null,
        .description = "Append one or multiple values to a list",
    });

    try registry.register(.{
        .name = "LPOP",
        .handler = list.lpop,
        .min_args = 2,
        .max_args = 3,
        .description = "Remove and return the first element of a list",
    });

    try registry.register(.{
        .name = "RPOP",
        .handler = list.rpop,
        .min_args = 2,
        .max_args = 3,
        .description = "Remove and return the last element of a list",
    });

    try registry.register(.{
        .name = "LLEN",
        .handler = list.llen,
        .min_args = 2,
        .max_args = 2,
        .description = "Get the length of a list",
    });

    try registry.register(.{
        .name = "LINDEX",
        .handler = list.lindex,
        .min_args = 3,
        .max_args = 3,
        .description = "Get an element from a list by its index",
    });

    try registry.register(.{
        .name = "LSET",
        .handler = list.lset,
        .min_args = 4,
        .max_args = 4,
        .description = "Set the value of an element in a list by its index",
    });

    try registry.register(.{
        .name = "LRANGE",
        .handler = list.lrange,
        .min_args = 4,
        .max_args = 4,
        .description = "Get a range of elements from a list",
    });

    try registry.register(.{
        .name = "APPEND",
        .handler = string.append,
        .min_args = 3,
        .max_args = 3,
        .description = "Append a value to a key",
    });

    try registry.register(.{
        .name = "STRLEN",
        .handler = string.strlen,
        .min_args = 2,
        .max_args = 2,
        .description = "Get the length of the value stored in a key",
    });

    try registry.register(.{
        .name = "GETSET",
        .handler = string.getset,
        .min_args = 3,
        .max_args = 3,
        .description = "Set a key and return its old value",
    });

    try registry.register(.{
        .name = "MGET",
        .handler = string.mget,
        .min_args = 2,
        .max_args = null,
        .description = "Get the values of multiple keys",
    });

    try registry.register(.{
        .name = "MSET",
        .handler = string.mset,
        .min_args = 3,
        .max_args = null,
        .description = "Set multiple key-value pairs",
    });

    try registry.register(.{
        .name = "SETEX",
        .handler = string.setex,
        .min_args = 4,
        .max_args = 4,
        .description = "Set a key with expiration time in seconds",
    });

    try registry.register(.{
        .name = "SETNX",
        .handler = string.setnx,
        .min_args = 3,
        .max_args = 3,
        .description = "Set a key only if it doesn't exist",
    });

    try registry.register(.{
        .name = "INCRBY",
        .handler = string.incrby,
        .min_args = 3,
        .max_args = 3,
        .description = "Increment a key by a specific amount",
    });

    try registry.register(.{
        .name = "DECRBY",
        .handler = string.decrby,
        .min_args = 3,
        .max_args = 3,
        .description = "Decrement a key by a specific amount",
    });

    try registry.register(.{
        .name = "INCRBYFLOAT",
        .handler = string.incrbyfloat,
        .min_args = 3,
        .max_args = 3,
        .description = "Increment a key by a floating point number",
    });

    return registry;
}
