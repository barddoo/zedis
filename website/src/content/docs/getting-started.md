---
title: Install and run
description: Build Zedis from source, run the server, talk to it with redis-cli, or pull a container image.
---

## Prerequisites

- [Zig](https://ziglang.org/download/) 0.17.1 — the exact version is pinned in
  `build.zig.zon`.
- `make` and a C compiler. `zig build` compiles LuaJIT from the `vendor/luajit`
  submodule, and TLS pulls in AWS-LC through ztls, so both are built from source.
  No system TLS library is needed.

A pre-built binary is available from the
[releases page](https://github.com/barddoo/zedis/releases) if you would rather skip
the toolchain.

## Build and run

```bash
# Clone with submodules — vendor/luajit is required for the build
git clone --recurse-submodules https://github.com/barddoo/zedis.git
cd zedis

# Build the project (optimized, ReleaseFast)
zig build --release=fast

# Run the server
zig build run --release=fast
```

The server listens on `127.0.0.1:6379` by default. It only reads a config file if
you pass one:

```bash
zig build run --release=fast -- ./zedis.conf
```

Already cloned without submodules? Run `git submodule update --init --recursive`
before building.

## Test it with redis-cli

Any Redis client works; `redis-cli` is the shortest path:

```bash
redis-cli -h 127.0.0.1 -p 6379
```

```text
127.0.0.1:6379> SET mykey "Hello, Zedis!"
OK
127.0.0.1:6379> GET mykey
"Hello, Zedis!"
127.0.0.1:6379> INCR counter
(integer) 1
127.0.0.1:6379> TYPE mykey
string
```

## Docker

Pre-built images are on [Docker Hub](https://hub.docker.com/r/barddoo/zedis):

```bash
docker run -p 6379:6379 barddoo/zedis
```

| Tag                                             | Base               | Notes               | Use case                   |
| ----------------------------------------------- | ------------------ | ------------------- | -------------------------- |
| `latest`, `x.x.x`, `x.x.x-debian`, `x.x.x-slim` | Debian Trixie slim | Larger, glibc base  | Default; broader ecosystem |
| `x.x.x-alpine`, `alpine`                        | Alpine 3.20        | Smallest with shell | Size-sensitive deployments |
| `x.x.x-distroless`                              | Distroless static  | No shell            | Security-sensitive         |

Persist data across restarts by mounting a volume:

```bash
docker run -p 6379:6379 -v zedis-data:/var/lib/zedis/data barddoo/zedis
```

Bring your own config:

```bash
docker run -p 6379:6379 -v ./zedis.conf:/etc/zedis/zedis.conf barddoo/zedis
```

Inside a container the KV budget defaults to 80% of the cgroup memory limit minus
fixed overhead, so `--memory` is respected without setting `maxmemory` by hand.
Outside a container it is a flat 256 MB plus a startup warning. See
[memory architecture](/architecture/memory/) for how the budget is enforced.

## Next

- [Configuration](/configuration/) — every directive and its default, including TLS.
- [Command compatibility](/compatibility/) before pointing a real workload at it.
- [Persistence](/persistence/) to choose between AOF and RDB.
