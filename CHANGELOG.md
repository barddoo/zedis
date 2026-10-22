# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Fixed

### Changed

### Removed

## [0.2.0] - 2026-10-22

### Added

- AOF writer thread with group commit: file I/O is offloaded to a dedicated OS thread, eliminating blocking fsyncs on the event loop. Under `appendfsync always`, throughput goes from ~450 rps to ~190k rps (420×).
- `executors` config key: accepts a number or `"auto"`. Defaults to `1`.
- `PEXPIREAT` command.

### Fixed

- Clock initialisation crash on Linux: the cached timestamp was undefined until the update coroutine ran, causing a panic in `toMilliseconds()` on the epoll backend where scheduler timing did not guarantee the coroutine ran first.
- `EXPIRE`, `SETEX`, and `PSETEX` are now rewritten to `PEXPIREAT` with an absolute millisecond timestamp before being logged to the AOF, so expiry times survive restart correctly.
- List write commands (`LPUSH`, `RPUSH`, `LPOP`, `RPOP`, `LSET`) were not logged to the AOF.
- Write commands are rejected with `-MISCONF` while the AOF writer thread is in a failure state (write error retried every second; fsync failure is permanent until restart), matching Redis behaviour.
- `TTL` returned the absolute expiry timestamp instead of the seconds remaining.
- `RENAME` of a key whose destination already existed hit `unreachable`.
- `INCR`, `DECR`, `INCRBY`, `DECRBY` replied with bulk strings instead of RESP integers.
- Error replies had the error code doubled (e.g. `-ERR ERR …`).
- `CONFIG` command was not registered.
- Unit tests were not executed under Zig 0.17 (the test runner reported success with zero tests run).

### Changed

- Migrated to Zig 0.17 and zio main.
- Default executor count changed from `auto` (one per CPU core) to `1`. With a single shared store lock, multiple executors add contention and cache pressure with no throughput benefit. On the benchmark workload this raised SET/GET throughput by 1.7× and dropped CPU use from ~450% to ~75%.
- Commands that are fully buffered in the socket read buffer are now parsed zero-copy in a single pass. Arg slices point directly into the read buffer instead of being copied into the parse arena. Removed the previous 64 KB inline-value limit; the maximum bulk string length is now 512 MB (matching Redis).
- Hash map entry array now grows geometrically (capacity doubles on each resize), removing the throughput cliff at high key counts. Insert throughput at 1M keys improved from 6.6k rps to 173k rps (26×).
- `aof_write_buffer_size` config key removed; internal buffer sizing is no longer exposed.
- Build optimisation mode set to `ReleaseFast` by default.

## [0.1.3] - 2026-06-14

### Fixed

- Fix AOF subsystem.
- Update Zig build flags for 0.16.0 API (CI/Docker).

### Changed

- Reduce allocations on hot paths (new `stack_writer.zig`, optimizations in server, store, and client).
- Consolidate test suite: inline tests into source files, remove `src/testing/` directory.
- Bump lalinsky/zio to v0.14.0.

## [0.1.2] - 2026-05-22

### Changed

- Upgrade to lalinsky/zio v0.12.0.
- Switch build optimization to ReleaseSafe for consistent behavior across platforms.

### Fixed

- Fix store access performance and command execution overhead.

## [0.1.1] - 2026-04-24

### Added

- Add CI workflow running tests on push to main and pull requests.
- Add multi-variant Docker images: alpine, debian-slim, and distroless.
- Add Docker Bake configuration for parallel multi-platform builds (linux/amd64, linux/arm64).
- Add Docker Hub publishing workflow on tag push.
- Add release binaries for linux-aarch64 and windows-x86_64.

### Fixed

- Fix config file loading hanging on async file reader EOF by switching to `readPositionalAll`.
- Fix Dockerfile: drop unnecessary build dependencies, fix symlink trailing slash, use nologin shell for service user, fix healthcheck.

### Changed

- Gate release binary builds on passing tests.
- Update all GitHub Actions to latest versions.

## [0.1.0] - 2026-04-23

### Added

- Add configuration file support with production-oriented defaults for memory, connections, and eviction tuning.
- Add client mailbox infrastructure for buffered server-to-client message delivery.
- Add server architecture and memory architecture documentation.

### Fixed

- Fix Zig 0.16 compatibility issues across the server, parser, store, and benchmark paths.
- Improve client/pubsub handle tracking during disconnect and mailbox delivery.

### Changed

- Migrate the runtime to Zig's newer I/O model and use `std.Io.Threaded` for the current server architecture.
- Refactor command execution around async connection tasks, a dedicated store thread, and mailbox-based response delivery.
- Rework store allocation, memory accounting, and eviction policy behavior.
- Remove multi-database support and keep Zedis intentionally single-store.
- Update benchmarking support and project documentation for the current architecture.

## [0.0.8] - 2026-01-28

### Added

- Bloom filter data structure

### Changed

- Use newer Zig master version

## [0.0.7] - 2026-01-01

### Changed

- Add clock cache
- Use newer Zig master version

## [0.0.6] - 2025-12-12

### Changed

- Fix a bunch of performance issues in #32
- Hash Table improved dramatically in #35
- Update Zig to v0.16, use new IO API in #36



## [0.0.5] - 2025-10-22

### Changed
- Update README to reflect release workflow changes
- Test the release badge in the README


## [0.0.4] - 2025-10-22

### Added
- Time Series: TS.RANGE command for querying samples within a time range
- CI: Add GitHub Action setup
- Testing: Additional unit tests for time series functionality

### Fixed
- Time Series: Correct sample storage in TS.ADD command
- Fix Gorilla compression

### Changed
- Update BitStream reader to use zero-allocation pattern


## [0.0.3-alpha] - 2025-10-12

### Added
- **Core Server Features**
  - Multi-threaded TCP server with connection handling
  - 16 databases (Redis-compatible, selectable via SELECT command)
  - Authentication support (AUTH command)
  - Fixed client pool with bitmap-based allocation
  - Configuration file support with production-ready defaults

- **Data Structures**
  - String operations with automatic type optimization (integers, short strings ≤23 bytes inline)
  - List operations with bidirectional traversal and negative index support
  - Time series data structures with Gorilla compression
  - String interning for memory-efficient key storage

- **String Commands** (19 commands)
  - SET, GET, DEL, INCR, DECR, APPEND, STRLEN, GETSET
  - MGET, MSET, SETEX, SETNX, INCRBY, DECRBY, INCRBYFLOAT
  - EXPIRE support for key expiration

- **List Commands** (8 commands)
  - LPUSH, RPUSH, LPOP, RPOP, LLEN, LINDEX, LSET, LRANGE
  - Supports negative indices (-1 for last element)

- **Key Commands** (7 commands)
  - EXISTS, KEYS (with glob pattern support), TTL, PERSIST, TYPE, RENAME, RANDOMKEY

- **Server Commands** (4 commands)
  - SAVE (synchronous RDB snapshots)
  - FLUSHDB, FLUSHALL (database clearing)
  - DBSIZE (key count)

- **Time Series Commands** (6 commands)
  - TS.CREATE (with retention, encoding, duplicate policy)
  - TS.ADD, TS.GET, TS.MGET, TS.INCRBY, TS.DECRBY, TS.ALTER

- **Pub/Sub System**
  - PUBLISH, SUBSCRIBE commands
  - Channel-based message distribution
  - Configurable subscriber limits per channel

- **Connection Commands** (5 commands)
  - AUTH, ECHO, PING, QUIT, HELP

- **Persistence**
  - RDB (Redis Database) format support for snapshots
  - AOF (Append-Only File) for command logging and replay
  - CRC64 checksum validation for data integrity

- **Memory Management**
  - Zero-allocation during command execution (TigerBeetle-inspired)
  - LRU eviction policies: allkeys_lru, volatile_lru, noeviction
  - Three-tier memory pool strategy (32B, 128B, 512B)
  - Custom KeyValueAllocator with eviction support
  - Configurable memory budgets (default: 2GB for KV store, 512MB for temp allocations)

- **Performance Optimizations**
  - SIMD-optimized string equality checks
  - CityHash64 for hash table operations
  - Optimal 75% load factor for hash table rehashing
  - Bidirectional list traversal optimized by starting from closest end

### Technical Details
- **Implementation**: Written in Zig 0.15.1
- **Protocol**: Redis Serialization Protocol (RESP)
- **Thread Safety**: One thread per client connection
- **Testing**: Comprehensive unit test suite with 100+ tests
- **Command Coverage**: 36% of Redis commands (~28 out of 77 common commands)

### Known Limitations
- AOF and RDB currently load only into database 0
- Pub/Sub UNSUBSCRIBE not yet implemented
- No support for Sets, Hashes, Sorted Sets, Streams, Transactions
- No Redis modules support
- FLUSHDB/FLUSHALL are synchronous only (no ASYNC mode)

[Unreleased]: https://github.com/bardoo/zedis/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/bardoo/zedis/compare/0.1.3...v0.2.0
[0.1.3]: https://github.com/bardoo/zedis/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/bardoo/zedis/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/bardoo/zedis/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/bardoo/zedis/releases/tag/0.1.0
