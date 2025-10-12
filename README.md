# Zedis

A Redis-compatible in-memory data store written in [Zig](https://ziglang.org/), designed for learning and experimentation. Zedis implements the core Redis protocol and data structures with a focus on simplicity, performance, and thread safety.

> Made for learning purposes. Not intended for production use **for now**.

## Features

- **Redis Protocol Compatibility**: Supports the Redis Serialization Protocol (RESP)locks.
- **Multiple Data Types**: String and integer value storage with automatic type conversion.
- **Core Commands**: Essential Redis commands including GET, SET, INCR, DECR, DEL, EXISTS, and TYPE.
- **High Performance**: Written in Zig for optimal performance and memory safety.
- **Connection Management**: Handles multiple concurrent client connections.
- **Disk persistence (RDB)**: Point-in-time snapshots of your dataset.
- **Memory Management**: No memory allocation during command execution.
- **Pub/Sub**: Decoupled communication between services.
- **Key Expiration**: Set time-to-live (TTL) for keys with background expiration handling.
- **Time Series**: Time series data structure. **New!**

## Roadmap

See the [open issues](https://github.com/barddoo/zedis/issues) for upcoming features and improvements.

## Quick Start

### Prerequisites

- [Zig](https://ziglang.org/download/) (minimum version 0.15.1)

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

### Memory Management

All memory allocations are handled during the initialization phase. No dynamic memory allocation occurs during command execution, ensuring high performance and predictability. Hugely inspired by this [article](https://tigerbeetle.com/blog/2022-10-12-a-database-without-dynamic-memory/).

### Building for Development

```bash
# Build in debug mode (default)
zig build -Doptimize=Debug

# Build optimized release
zig build -Doptimize=ReleaseFast

# Run tests (when available)
zig build test
```

## Contact

- GitHub: [@barddoo](https://github.com/barddoo)
- Project Link: [https://github.com/barddoo/zedis](https://github.com/barddoo/zedis)
- LinkedIn: [Charles Fonseca](https://www.linkedin.com/in/charlesjrfonseca/)

## Thanks
- [Andrew Kelley](https://andrewkelley.me) - For creating the amazing [Zig Language](https://ziglang.org/).
- [Redis](https://redis.io/) - For the inspiration and protocol design.
- [TigerBeetle](https://tigerbeetle.com/) - For the memory management and the tiger style.
- [Karl Seguin](https://github.com/karlseguin) - For the great articles.
