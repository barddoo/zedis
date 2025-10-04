# Redis Commands Compatibility

This document outlines the compatibility of Zedis with Redis commands. The table below shows which Redis commands are implemented, partially implemented, or not yet supported.

## Legend
- **Yes**: Fully implemented and compatible with Redis
- **No**: Not implemented
- **Partially**: Partially implemented with some limitations

## Connection Commands

| Command | Supported | Notes                                       |
| ------- | --------- | ------------------------------------------- |
| AUTH    | Yes       | Authentication command                      |
| ECHO    | Yes       | Echo back the given string                  |
| PING    | Yes       | Ping the server (supports optional message) |
| QUIT    | Yes       | Close the connection                        |
| HELP    | Yes       | Show help message                           |

## String Commands

| Command     | Supported | Notes                                       |
| ----------- | --------- | ------------------------------------------- |
| SET         | Yes       | Set string value of a key                   |
| GET         | Yes       | Get string value of a key                   |
| DEL         | Yes       | Delete one or more keys                     |
| INCR        | Yes       | Increment the integer value of a key by one |
| DECR        | Yes       | Decrement the integer value of a key by one |
| EXPIRE      | Yes       | Set expiration time for a key               |
| APPEND      | Yes       | Append a value to a key                     |
| STRLEN      | Yes       | Get the length of the value stored in a key |
| GETSET      | Yes       | Set a key and return its old value          |
| MGET        | Yes       | Get the values of multiple keys             |
| MSET        | Yes       | Set multiple key-value pairs                |
| SETEX       | Yes       | Set a key with expiration time              |
| SETNX       | Yes       | Set a key only if it doesn't exist          |
| INCRBY      | Yes       | Increment a key by a specific amount        |
| DECRBY      | Yes       | Decrement a key by a specific amount        |
| INCRBYFLOAT | Yes       | Increment a key by a floating point number  |

## Key Commands

| Command   | Supported | Notes                               |
| --------- | --------- | ----------------------------------- |
| EXISTS    | No        | Check if key exists                 |
| KEYS      | No        | Find all keys matching a pattern    |
| TTL       | No        | Get remaining time to live of a key |
| PERSIST   | No        | Remove expiration from a key        |
| TYPE      | No        | Get the data type of a key          |
| RENAME    | No        | Rename a key                        |
| RANDOMKEY | No        | Return a random key                 |

## List Commands

| Command | Supported | Notes                                          |
| ------- | --------- | ---------------------------------------------- |
| LPUSH   | Yes       | Push elements to the head of a list            |
| RPUSH   | Yes       | Push elements to the tail of a list            |
| LPOP    | Yes       | Remove and return the first element of a list  |
| RPOP    | Yes       | Remove and return the last element of a list   |
| LLEN    | Yes       | Get the length of a list                       |
| LINDEX  | Yes       | Get an element from a list by index            |
| LSET    | Yes       | Set the value of an element in a list by index |
| LRANGE  | Yes       | Get a range of elements from a list            |

## Set Commands

| Command   | Supported | Notes                                 |
| --------- | --------- | ------------------------------------- |
| SADD      | No        | Add members to a set                  |
| SREM      | No        | Remove members from a set             |
| SMEMBERS  | No        | Get all members of a set              |
| SCARD     | No        | Get the number of members in a set    |
| SISMEMBER | No        | Check if a value is a member of a set |
| SINTER    | No        | Get the intersection of sets          |
| SUNION    | No        | Get the union of sets                 |
| SDIFF     | No        | Get the difference of sets            |

## Hash Commands

| Command | Supported | Notes                          |
| ------- | --------- | ------------------------------ |
| HSET    | No        | Set hash field                 |
| HGET    | No        | Get hash field value           |
| HMSET   | No        | Set multiple hash fields       |
| HMGET   | No        | Get multiple hash field values |
| HGETALL | No        | Get all hash fields and values |
| HDEL    | No        | Delete hash fields             |
| HEXISTS | No        | Check if hash field exists     |
| HKEYS   | No        | Get all hash field names       |
| HVALS   | No        | Get all hash values            |
| HLEN    | No        | Get number of fields in a hash |

## Sorted Set Commands

| Command | Supported | Notes                                      |
| ------- | --------- | ------------------------------------------ |
| ZADD    | No        | Add members to a sorted set                |
| ZREM    | No        | Remove members from a sorted set           |
| ZRANGE  | No        | Get members in a sorted set by index range |
| ZRANK   | No        | Get the rank of a member in a sorted set   |
| ZSCORE  | No        | Get the score of a member in a sorted set  |
| ZCARD   | No        | Get the number of members in a sorted set  |

## Pub/Sub Commands

| Command      | Supported | Notes                                   |
| ------------ | --------- | --------------------------------------- |
| PUBLISH      | Yes       | Publish a message to a channel          |
| SUBSCRIBE    | Yes       | Subscribe to channels                   |
| UNSUBSCRIBE  | No        | Unsubscribe from channels               |
| PSUBSCRIBE   | No        | Subscribe to channels matching patterns |
| PUNSUBSCRIBE | No        | Unsubscribe from pattern subscriptions  |

## Stream Commands

| Command    | Supported | Notes                                          |
| ---------- | --------- | ---------------------------------------------- |
| XADD       | No        | Add entry to a stream                          |
| XREAD      | No        | Read entries from streams                      |
| XRANGE     | No        | Return range of entries from stream            |
| XREVRANGE  | No        | Return range of entries from stream in reverse |
| XLEN       | No        | Get number of entries in a stream              |
| XTRIM      | No        | Trim stream to specified length                |
| XDEL       | No        | Delete entries from stream                     |
| XGROUP     | No        | Manage consumer groups                         |
| XREADGROUP | No        | Read entries from stream via consumer group    |
| XACK       | No        | Acknowledge processed entries                  |
| XCLAIM     | No        | Claim pending entries                          |
| XPENDING   | No        | Get pending entries information                |
| XINFO      | No        | Get stream information                         |

## Transaction Commands

| Command | Supported | Notes                  |
| ------- | --------- | ---------------------- |
| MULTI   | No        | Start a transaction    |
| EXEC    | No        | Execute a transaction  |
| DISCARD | No        | Discard a transaction  |
| WATCH   | No        | Watch keys for changes |
| UNWATCH | No        | Stop watching keys     |

## Server Commands

| Command    | Supported | Notes                                      |
| ---------- | --------- | ------------------------------------------ |
| SAVE       | Yes       | Synchronously save dataset to RDB file     |
| BGSAVE     | No        | Asynchronously save dataset to RDB file    |
| FLUSHDB    | No        | Clear current database                     |
| FLUSHALL   | No        | Clear all databases                        |
| INFO       | No        | Get server information                     |
| CONFIG GET | No        | Get configuration parameters               |
| CONFIG SET | No        | Set configuration parameters               |
| DBSIZE     | No        | Get number of keys in database             |
| LASTSAVE   | No        | Get Unix timestamp of last save            |
| MONITOR    | No        | Listen for all requests received by server |

## Redis Modules

Redis modules extend Redis functionality with custom data types and commands. Zedis currently does not support Redis modules.

### Popular Redis Modules

| Module          | Supported | Notes                                               |
| --------------- | --------- | --------------------------------------------------- |
| RedisJSON       | No        | JSON data type and operations                       |
| RediSearch      | No        | Full-text search and indexing                       |
| RedisGraph      | No        | Graph database functionality                        |
| RedisTimeSeries | No        | Time series data structures                         |
| RedisBloom      | No        | Probabilistic data structures (Bloom filters, etc.) |
| RedisGears      | No        | Programmable data processing engine                 |

### Module System

| Feature           | Supported | Notes                            |
| ----------------- | --------- | -------------------------------- |
| Module Loading    | No        | Dynamic loading of Redis modules |
| Module Commands   | No        | Custom commands from modules     |
| Module Data Types | No        | Custom data types from modules   |
| Module APIs       | No        | Module development APIs          |

## Summary

**Total Commands**: 77
- **Fully Implemented**: 28 commands
- **Partially Implemented**: 0 commands
- **Not Implemented**: 49 commands

**Implementation Coverage**: ~36%

This compatibility matrix will be updated as new commands are implemented in Zedis.