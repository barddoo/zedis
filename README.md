# Zedis

[![Release](https://github.com/barddoo/zedis/actions/workflows/release.yml/badge.svg)](https://github.com/barddoo/zedis/actions/workflows/release.yml)
<a href="https://hackergit.org/r/barddoo/zedis"><img src="https://hackergit.org/badge/barddoo/zedis.svg" alt="Hacker News" height="20"></a>

A Redis-compatible in-memory data store written in [Zig](https://ziglang.org/), designed for learning and experimentation. Zedis implements the core Redis protocol and data structures with a focus on simplicity, performance, and thread safety.

**Not intended for production use yet.**

## Features

- **Redis Protocol Compatibility**: Supports the Redis Serialization Protocol (RESP),
  including pipelined commands.
- **Multiple Data Types**: Strings and integers, lists, time series, and Bloom filters.
- **Core Commands**: Key management (`DEL`, `EXISTS`, `TYPE`, `TTL`, `EXPIRE`, `KEYS`),
  strings, lists (`LPUSH`/`RPUSH`/`LRANGE`, ...), and `RANDOMKEY`.
- **High Performance**: Written in Zig, with a single-executor command path and no
  global store lock.
- **Key Expiration**: Lazy TTL expiry on access, plus expiry checks during eviction.
- **Disk persistence (RDB)**: Point-in-time snapshots of your dataset.
- **Append-only file (AOF)**: Durable write-ahead logging with group commit.
- **Memory Budgeting**: Redis-compatible `maxmemory` with eviction, `-OOM` rejection
  for allocating commands, and cgroup-aware auto-sizing inside containers.
- **Pub/Sub**: Decoupled communication between services, with push delivery to idle
  subscribers.
- **TLS**: Optional TLS 1.2/1.3 listener (OpenSSL) with certificate/key/CA
  configuration and optional mutual TLS via `tls-auth-clients`.
- **Observability**: Real `INFO` counters (connections, ops/sec, hit rate,
  memory, AOF state), `SLOWLOG`, `LATENCY`, and a `METRICS` command exposing
  Prometheus text exposition.
- **Graceful shutdown**: `SIGINT`/`SIGTERM` and `SHUTDOWN [NOSAVE|SAVE]` stop
  accepting, drain clients, flush the AOF, and close the listeners. `CONFIG
  REWRITE` persists runtime changes.
- **Time Series**: Time series data structure. **Now with Gorilla compression!**
- **Opinionated Design**: No multiple logical databases, expiry is lazy only.

## Caveats

- Zedis is intentionally single-store. It does not support multiple logical databases and does not expose Redis `SELECT`. It adds complexity and segment memory. This follows the reasoning Salvatore Sanfilippo gave when he called Redis multiple databases one of [his worst design decisions](https://groups.google.com/g/redis-db/c/vS5wX8X4Cjg/m/8ounBXitG4sJ).


## Quick Start

Download the binary from the [releases page](https://github.com/barddoo/zedis/releases) or build from source to get started with Zedis.

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.17.1 (pinned in `build.zig.zon`)

### Building and Running

```bash
# Clone the repository
git clone https://github.com/barddoo/zedis.git
cd zedis

# Build the project (optimized, ReleaseFast)
zig build --release=fast

# Run the server
zig build run --release=fast
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

### TLS

Enable the TLS listener in the config file (see `zedis.conf` for all options):

```conf
port 0                 # optional: serve TLS only
tls-port 6380
tls-cert-file /etc/zedis/server.crt
tls-key-file /etc/zedis/server.key
tls-ca-cert-file /etc/zedis/ca.crt
tls-auth-clients no    # yes (default), no, or optional
```

Then connect with any TLS-capable Redis client, for example:

```bash
redis-cli --tls --insecure -p 6380
```

## Docker

Pre-built images are available on [Docker Hub](https://hub.docker.com/r/barddoo/zedis):

```bash
docker run -p 6379:6379 barddoo/zedis
```

### Variants

| Tag                                             | Base               | Notes               | Use case                   |
| ----------------------------------------------- | ------------------ | ------------------- | -------------------------- |
| `latest`, `x.x.x`, `x.x.x-debian`, `x.x.x-slim` | Debian Trixie slim | Larger, glibc base  | Default; broader ecosystem |
| `x.x.x-alpine`, `alpine`                        | Alpine 3.20        | Smallest with shell | Size-sensitive deployments |
| `x.x.x-distroless`                              | Distroless static  | No shell            | Security-sensitive         |

### Persistent data

Mount a volume to persist data across restarts:

```bash
docker run -p 6379:6379 -v zedis-data:/var/lib/zedis/data barddoo/zedis
```

### Custom config

```bash
docker run -p 6379:6379 -v ./zedis.conf:/etc/zedis/zedis.conf barddoo/zedis
```

## Development

### Project Structure

The codebase is split by responsibility:

- `src/app/` — server lifecycle, client connections, config, clock
- `src/storage/` — store, KV allocator, lists, time series, Bloom filters, search
- `src/commands/` — command handlers and registry
- `src/persistence/` — AOF and RDB
- `src/protocol/` — RESP parser and serializer
- `src/util/` — mailbox, stack writer, types, compression
- `src/benchmarks/` — micro/load benchmarks

See `docs/server-architecture.md` for the current server thread model and request flow.

### Memory Management

See `docs/memory-architecture.md` for the current allocator layout, memory budgets, and runtime allocation behavior. See `docs/store-cache-layout.md` for the store's hash-table layout and cache behavior.

### Building for Development

TLS support links OpenSSL. On macOS install it with `brew install openssl@4`
(the build auto-detects the Homebrew keg); on Debian/Ubuntu install
`libssl-dev`, and on Alpine install `openssl-dev openssl-libs-static`.
OpenSSL is linked statically by default; pass `-Dopenssl-static=false` for a
dynamic link, or `-Dopenssl-prefix=/path` for a non-standard prefix.

```bash
# Build in debug mode (default)
zig build

# Build optimized release (ReleaseFast; use this for benchmarks and performance testing)
zig build --release=fast

# `--release` with no mode also picks ReleaseFast (the preferred mode in build.zig)
zig build --release

# Run the full test suite
zig build test

# Run a focused subset
zig build test -Dtest-filter="Store"

# Format the source
zig fmt .
```

## AI Disclaimer

This project was developed with some AI help. Most of the code was written by hand.

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
