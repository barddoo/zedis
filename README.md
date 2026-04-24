# Zedis

[![Release](https://github.com/barddoo/zedis/actions/workflows/release.yml/badge.svg)](https://github.com/barddoo/zedis/actions/workflows/release.yml)

A Redis-compatible in-memory data store written in [Zig](https://ziglang.org/), designed for learning and experimentation. Zedis implements the core Redis protocol and data structures with a focus on simplicity, performance, and thread safety.

> Made for learning purposes. Not intended for production use **for now**.

## Features

- **Redis Protocol Compatibility**: Supports the Redis Serialization Protocol (RESP)locks.
- **Multiple Data Types**: String and integer value storage with automatic type conversion.
- **Core Commands**: Essential Redis commands including GET, SET, INCR, DECR, DEL, EXISTS, and TYPE.
- **High Performance**: Written in Zig for optimal performance and memory safety.
- **Key Expiration**: Set time-to-live (TTL) for keys with background expiration handling.
- **Disk persistence (RDB)**: Point-in-time snapshots of your dataset.
- **Append-only file (AOF)**: Durable write-ahead logging for data recovery.
- **Memory Budgeting**: Eviction-aware KV allocator, fixed client slot pool, and separate temporary allocation paths.
- **Pub/Sub**: Decoupled communication between services.
- **Time Series**: Time series data structure. **Now with Gorilla compression!**

## Caveats

- Zedis is intentionally single-store. It does not support multiple logical databases and does not expose Redis `SELECT`. It adds complexity and segment memory. This follows the reasoning Salvatore Sanfilippo gave when he called Redis multiple databases one of his worst design decisions: https://groups.google.com/g/redis-db/c/vS5wX8X4Cjg/m/8ounBXitG4sJ

## Roadmap

See the [open issues](https://github.com/barddoo/zedis/issues) for upcoming features and improvements.

## Quick Start

Download the binary from the [releases page](https://github.com/barddoo/zedis/releases) or build from source to get started with Zedis.

### Prerequisites

- [Zig](https://ziglang.org/download/) master branch (required for latest language features)

### Building and Running

```bash
# Clone the repository
git clone https://github.com/barddoo/zedis.git
cd zedis

# Build the project
zig build

# Run the server
zig build run
```

The server will start on `127.0.0.1:6379` by default.

### Testing with Redis CLI

You can test Zedis using the standard `redis-cli` or any Redis client:

```bash
# Connect to Zedis
redis-cli -h 127.0.0.1 -p 6379

# Try some commands
127.0.0.1:6379> SET mykey "Hello, Zedis!"
OK
127.0.0.1:6379> GET mykey
"Hello, Zedis!"
127.0.0.1:6379> INCR counter
(integer) 1
127.0.0.1:6379> TYPE mykey
string
```

## Development

### Project Structure

The codebase follows Zig conventions with clear separation of concerns:

- Type-safe operations with compile-time guarantees
- Explicit error handling throughout
- Memory safety
- Modular design for easy extension
- Comprehensive logging for debugging

See `docs/server-architecture.md` for the current server thread model and request flow.

### Memory Management

See `docs/memory-architecture.md` for the current allocator layout, memory budgets, and runtime allocation behavior.

### Building for Development

```bash
# Build in debug mode (default)
zig build -Doptimize=Debug

# Build optimized release
zig build -Doptimize=ReleaseFast

# Run tests (when available)
zig build test
```

## Contributing

Contributors are welcome! Whether you're fixing bugs, adding features, improving documentation, or suggesting enhancements, your contributions are appreciated.

Feel free to:

- Open an issue to report bugs or suggest features
- Submit pull requests with improvements
- Share feedback and ideas

Check out the [open issues](https://github.com/barddoo/zedis/issues) to see where you can help.

## Stay Connected

- Subscribe to my [newsletter](https://charlesfonseca.substack.com)

## Thanks

- [Andrew Kelley](https://andrewkelley.me) - For creating the amazing [Zig Language](https://ziglang.org/).
- [Redis](https://redis.io/) - For the inspiration and protocol design.
- [TigerBeetle](https://tigerbeetle.com/) - For the memory management and the tiger style.
- [Karl Seguin](https://github.com/karlseguin) - For the great articles.
