# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Fixed

### Changed

### Removed

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

[Unreleased]: https://github.com/bardoo/zedis/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/bardoo/zedis/releases/tag/v0.1.0
