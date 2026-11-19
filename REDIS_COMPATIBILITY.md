# Redis Commands Compatibility

This document outlines the compatibility of Zedis with Redis commands. The table below shows which Redis commands are implemented, partially implemented, or not yet supported.

## Legend
- **Yes**: Fully implemented and compatible with Redis
- **No**: Not implemented
- **Partially**: Partially implemented with some limitations

Commands marked **Yes** can still cover only part of the subcommand or option
set; the Notes column says where.

## Connection Commands

| Command | Supported | Notes                                                                 |
| ------- | --------- | --------------------------------------------------------------------- |
| AUTH    | Yes       | Password only; ACL users are not supported                            |
| CLIENT  | Partial   | ID, SETNAME, GETNAME, and SETINFO (LIB-NAME, LIB-VER); no KILL or LIST |
| COMMAND | Partial   | Bare form, COUNT, LIST, INFO, DOCS, and GETKEYS                        |
| ECHO    | Yes       | Echo back the given string                                             |
| HELLO   | Yes       | Switches RESP2/RESP3; AUTH and SETNAME options                         |
| HELP    | Yes       | Top-level command list (Zedis extension; Redis only has `<CMD> HELP`)  |
| PING    | Yes       | Ping the server (supports optional message)                            |
| QUIT    | Yes       | Close the connection                                                   |
| RESET   | Partial   | Resets the command name and RESP version only; auth and MULTI state stay |
| SELECT  | Yes       | Only database 0 exists                                                 |

## String Commands

| Command     | Supported | Notes                                                                    |
| ----------- | --------- | ------------------------------------------------------------------------ |
| SET         | Yes       | NX, XX, EX, PX, EXAT, PXAT, GET, and KEEPTTL                             |
| GET         | Yes       | Get the value of a key                                                   |
| GETDEL      | Yes       | Get a value and delete the key                                           |
| GETEX       | Yes       | EX, PX, EXAT, PXAT, and PERSIST                                          |
| GETRANGE    | Yes       | Get a substring of a string value                                        |
| SUBSTR      | Yes       | Alias for GETRANGE                                                       |
| SETRANGE    | Yes       | Overwrite part of a string at an offset                                  |
| APPEND      | Yes       | Append a value to a key                                                  |
| STRLEN      | Yes       | Get the length of the value stored in a key                              |
| SETEX       | Yes       | Set a key with a TTL in seconds                                          |
| PSETEX      | Yes       | Set a key with a TTL in milliseconds                                     |
| SETNX       | Yes       | Set a key only if it does not exist                                      |
| MSET        | Yes       | Set multiple key-value pairs                                             |
| MSETNX      | Yes       | Set multiple keys only if none of them exist                             |
| MGET        | Yes       | Get the values of multiple keys                                          |
| GETSET      | Yes       | Set a key and return its old value                                       |
| INCR        | Yes       | Increment the integer value of a key by one                              |
| INCRBY      | Yes       | Increment a key by a specific amount                                     |
| INCRBYFLOAT | Yes       | Increment a key by a floating-point number                               |
| DECR        | Yes       | Decrement the integer value of a key by one                              |
| DECRBY      | Yes       | Decrement a key by a specific amount                                     |

## Key Commands

| Command    | Supported | Notes                                                                     |
| ---------- | --------- | ------------------------------------------------------------------------- |
| DEL        | Yes       | Delete one or more keys                                                   |
| UNLINK     | Yes       | Delete keys (synchronous free)                                            |
| EXISTS     | Yes       | Check if keys exist                                                       |
| KEYS       | Yes       | O(N) and blocking; prefer SCAN. Aborts with `-TIMEOUT` when `command-timeout-ms` is set |
| SCAN       | Yes       | Cursor iteration with MATCH, COUNT, and TYPE                               |
| TTL        | Yes       | Get remaining time to live in seconds                                     |
| PTTL       | Yes       | Get remaining time to live in milliseconds                                |
| EXPIRETIME | Yes       | Get the expiry as a Unix timestamp in seconds                             |
| PEXPIRETIME | Yes      | Get the expiry as a Unix timestamp in milliseconds                        |
| PERSIST    | Yes       | Remove the expiration from a key                                          |
| EXPIRE     | Yes       | NX, XX, GT, and LT options                                                |
| PEXPIRE    | Yes       | NX, XX, GT, and LT options                                                |
| EXPIREAT   | Partial   | Absolute expiry only; NX, XX, GT, and LT are not parsed                    |
| PEXPIREAT  | Partial   | Absolute expiry only; NX, XX, GT, and LT are not parsed                    |
| TYPE       | Yes       | Reports string, list, hash, tseries-type, bloom_filter, or search_index    |
| RENAME     | Yes       | Rename a key                                                              |
| RANDOMKEY  | Yes       | Return a random key                                                       |
| COPY       | Yes       | Supports REPLACE; no DB option                                            |
| OBJECT     | Partial   | ENCODING, REFCOUNT, IDLETIME, FREQ, and HELP; REFCOUNT and IDLETIME are stubs |

## List Commands

| Command | Supported | Notes                                          |
| ------- | --------- | ---------------------------------------------- |
| LPUSH   | Yes       | Push elements to the head of a list            |
| RPUSH   | Yes       | Push elements to the tail of a list            |
| LPOP    | Yes       | Remove and return the first element; optional count |
| RPOP    | Yes       | Remove and return the last element; optional count  |
| LLEN    | Yes       | Get the length of a list                       |
| LINDEX  | Yes       | Get an element from a list by index            |
| LSET    | Yes       | Set the value of an element in a list by index |
| LRANGE  | Yes       | Get a range of elements from a list            |
| LREM    | Yes       | Remove elements matching a value               |
| LTRIM   | Yes       | Trim a list to a range                         |
| LINSERT | Yes       | Insert BEFORE or AFTER a pivot element         |

Blocking list commands (`BLPOP`, `BRPOP`, `BRPOPLPUSH`, `BLMOVE`), `LMOVE`, and
`RPOPLPUSH` are not implemented.

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

| Command      | Supported | Notes                                  |
| ------------ | --------- | -------------------------------------- |
| HSET         | Yes       | Set hash field(s)                      |
| HMSET        | Yes       | Deprecated alias for HSET              |
| HGET         | Yes       | Get hash field value                   |
| HMGET        | Yes       | Get multiple hash field values         |
| HGETALL      | Yes       | Get all hash fields and values         |
| HDEL         | Yes       | Delete hash fields                     |
| HEXISTS      | Yes       | Check if a hash field exists           |
| HKEYS        | Yes       | Get all hash field names               |
| HVALS        | Yes       | Get all hash values                    |
| HLEN         | Yes       | Get the number of fields in a hash     |
| HSETNX       | Yes       | Set a hash field only if it does not exist |
| HINCRBY      | Yes       | Increment a hash field by an integer   |
| HINCRBYFLOAT | Yes       | Increment a hash field by a float      |

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
| UNSUBSCRIBE  | Yes       | Unsubscribe from channels               |
| PSUBSCRIBE   | No        | Subscribe to channels matching patterns |
| PUNSUBSCRIBE | No        | Unsubscribe from pattern subscriptions  |
| PUBSUB       | No        | Channel introspection                   |

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

| Command | Supported | Notes                                    |
| ------- | --------- | ---------------------------------------- |
| MULTI   | Yes       | Start a transaction                      |
| EXEC    | Yes       | Execute a transaction                    |
| DISCARD | Yes       | Discard a transaction                    |
| WATCH   | No        | Watch keys for changes                   |
| UNWATCH | No        | Stop watching keys                       |

## Scripting Commands

| Command | Supported | Notes                                    |
| ------- | --------- | ---------------------------------------- |
| EVAL    | Yes       | Execute a Lua script server-side         |
| EVALSHA | Yes       | Execute a cached Lua script by SHA1      |
| SCRIPT  | Yes       | LOAD, EXISTS, and FLUSH                  |
| FUNCTION | No       | Redis Functions are not supported        |

## Server Commands

| Command    | Supported | Notes                                                     |
| ---------- | --------- | --------------------------------------------------------- |
| SAVE       | Yes       | Synchronously save the dataset to an RDB file             |
| BGSAVE     | No        | Asynchronously save the dataset to an RDB file            |
| BGREWRITEAOF | Yes     | Rewrite the AOF as a snapshot of the dataset              |
| FLUSHDB    | Partial   | Synchronous only; no ASYNC or SYNC option                 |
| FLUSHALL   | Partial   | Alias of FLUSHDB in single-store mode                     |
| INFO       | Yes       | Sections: server, clients, memory, persistence, stats, replication, cpu, commandstats, latencystats, keyspace |
| CONFIG     | Partial   | GET, SET, REWRITE, RESETSTAT, and HELP; a subset of Redis parameters |
| METRICS    | Yes       | Prometheus text exposition (Zedis extension)              |
| SLOWLOG    | Yes       | GET, LEN, RESET, and HELP                                 |
| LATENCY    | Yes       | LATEST, HISTORY, RESET, DOCTOR, and HELP                  |
| SHUTDOWN   | Yes       | NOSAVE (default) or SAVE, then flush the AOF              |
| DBSIZE     | Yes       | Get the number of keys in the single store                |
| LASTSAVE   | No        | Get the Unix timestamp of the last save                   |
| MONITOR    | No        | Listen for all requests received by the server            |

`MEMORY`, `ACL`, `CLUSTER`, and `WAIT` are not implemented.

## Redis Modules

Redis modules extend Redis functionality with custom data types and commands. Zedis does not load Redis modules. A few RedisBloom and RedisTimeSeries commands are implemented natively and are listed below.

## Bloom Filter

| Command    | Supported | Notes                                                    |
| ---------- | --------- | -------------------------------------------------------- |
| BF.RESERVE | Yes       | Create a Bloom filter with error rate, capacity, EXPANSION, and NONSCALING |
| BF.ADD     | Yes       | Add an item to a Bloom filter                            |
| BF.MADD    | Yes       | Add multiple items to a Bloom filter                     |
| BF.EXISTS  | Yes       | Check if an item may exist in a Bloom filter             |
| BF.MEXISTS | Yes       | Check multiple items at once                             |
| BF.INFO    | Yes       | Get information about a Bloom filter                     |
| BF.INSERT  | Yes       | Add items, creating the filter if it does not exist      |

`BF.SCANDUMP`, `BF.LOADCHUNK`, and `CF.*` are not implemented.

## Time Series

| Command       | Supported | Notes                                                                                                           |
| ------------- | --------- | --------------------------------------------------------------------------------------------------------------- |
| TS.CREATE     | Yes       | Retention, ENCODING, DUPLICATE_POLICY, and IGNORE parameters                                                    |
| TS.ADD        | Yes       | Duplicate policy and IGNORE filtering                                                                           |
| TS.GET        | Yes       | Get the latest sample (supports LATEST)                                                                         |
| TS.MGET       | No        | Get the latest samples from multiple time series                                                                |
| TS.MADD       | No        | Add multiple samples to multiple time series                                                                    |
| TS.RANGE      | Yes       | Time range with COUNT and AGGREGATION                                                                            |
| TS.MRANGE     | No        | Get samples in a time range from multiple time series                                                           |
| TS.INCRBY     | Yes       | Increment the latest sample by a value                                                                          |
| TS.DECRBY     | Yes       | Decrement the latest sample by a value                                                                          |
| TS.CREATERULE | No        | Create a downsampling rule                                                                                      |
| TS.DELETERULE | No        | Delete a downsampling rule                                                                                      |
| TS.ALTER      | Yes       | Alter the configuration of a time series                                                                        |

## RediSearch (FT)

The FT command handlers and the search index data type exist in the source,
but the commands are not registered in the command table, so a running server
replies with an unknown command. Treat FT as unsupported.

| Command      | Supported | Notes                                      |
| ------------ | --------- | ------------------------------------------ |
| FT.CREATE    | No        | Handler exists but is not registered       |
| FT.DROPINDEX | No        | Handler exists but is not registered       |
| FT._LIST     | No        | Handler exists but is not registered       |
| FT.INFO      | No        | Handler exists but is not registered       |
| FT.ADD       | No        | Handler exists but is not registered       |
| FT.DEL       | No        | Handler exists but is not registered       |
| FT.GET       | No        | Handler exists but is not registered       |
| FT.SEARCH    | No        | Handler exists but is not registered       |

## Popular Redis Modules

| Module          | Supported | Notes                                                              |
| --------------- | --------- | ------------------------------------------------------------------ |
| RedisJSON       | No        | JSON data type and operations                                      |
| RediSearch      | No        | FT handlers exist but are not registered                           |
| RedisGraph      | No        | Graph database functionality                                       |
| RedisTimeSeries | Partial   | Core TS commands (see Time Series section)                         |
| RedisBloom      | Partial   | BF commands (see Bloom Filter section)                             |
| RedisGears      | No        | Programmable data processing engine                                |

## Module System

| Feature           | Supported | Notes                            |
| ----------------- | --------- | -------------------------------- |
| Module Loading    | No        | Dynamic loading of Redis modules |
| Module Commands   | No        | Custom commands from modules     |
| Module Data Types | No        | Custom data types from modules   |
| Module APIs       | No        | Module development APIs          |

## Summary

**Total Commands**: 157 listed in this document

- **Fully Implemented**: 99 commands
- **Partially Implemented**: 9 commands (all with a subset of subcommands or options; see Notes)
- **Not Implemented**: 49 commands
- **Implementation Coverage**: ~69% (108 of 157 listed commands)

This compatibility matrix will be updated as new commands are implemented in Zedis.
