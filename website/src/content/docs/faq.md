---
title: FAQ
description: Short answers to the questions that come up before anyone reads the architecture pages.
---

## Is it production ready?

We're getting there. The protocol, persistence, memory budgeting, and TLS paths
are real and exercised, not scaffolding. What is still missing is operational
surface: a single node with no replication, no cluster mode, and no ACLs. Run your
own workload against it and keep backups before you depend on it.

## Why does it use a single executor?

Because store access is serialized either way. With multiple executors, coroutines
and the store bounce between threads on every command, adding contention and cache
pressure for no throughput gain. On the benchmark workload one executor ran at
~2.66M rps on ~0.75 cores; `.auto` ran at ~1.2M rps using ~4.5 cores. The full
argument is in [server architecture](/architecture/overview/#why-one-executor).

## Why no multiple databases or `SELECT`?

Multiple logical databases add complexity and segment memory for a feature most
applications never use correctly. `SELECT 0` is accepted for client compatibility;
any other index is rejected. Salvatore Sanfilippo's own retrospective on Redis'
multiple databases is the reasoning. Namespace your keys instead.

## Why is expiry lazy?

There is no active expiry cycle walking the keyspace. Expired keys stop being
visible immediately, and eviction prefers expired entries, but memory is only
reclaimed when something touches the key or pressure forces eviction. It keeps the
server simple and avoids background work competing with commands. The cost is
memory on TTL-heavy workloads that are never read — see
[migrating from Redis](/migrating-from-redis/#expiry-is-lazy).

## Where are the benchmarks?

`benchmark-comparison.md` in the repository root. They are single-run results on one
machine, which is why they are not published as a page here: treat the ratios as
directional, and re-run them for your own hardware with `zig build --release=fast`.

## Can I keep using my Redis client?

Almost certainly. Zedis speaks RESP2 and RESP3, including pipelined commands, so
`redis-cli`, Jedis, redis-py, node-redis, ioredis and friends connect and work. What
breaks is listed in [migrating from Redis](/migrating-from-redis/): `SELECT` beyond
0, `WATCH`, streams, ACL two-argument `AUTH`, and the 39 commands that are not
implemented.

## How is memory sized?

Inside a container: 80% of the cgroup limit minus fixed overhead, with a 64 MB
floor. Outside a container: a flat 256 MB, with a warning, because guessing is
worse than a warning. `maxmemory` (or its alias `kv-memory-budget`) overrides both,
and `0` means unlimited like Redis. If cgroup files exist but cannot be read, the
server refuses to start. Details in [memory architecture](/architecture/memory/).

## Do I need to run with `maxmemory-policy`?

The default is `allkeys-lru`. With `noeviction`, allocating commands are rejected
with `-OOM` once the budget cannot be freed, which is the Redis behaviour. If you
enable the disk tier you *must* use an LRU policy: `noeviction` keeps no LRU index,
so it cannot spill.

## What is the disk tier?

`disk-storage yes` adds a cold-value tier backed by TidesDB. Cold string values are
spilled at the command boundary before eviction runs; keys, TTLs, and types stay in
memory. It is a milestone feature: reads materialize synchronously on the executor,
and `SAVE`/`BGREWRITEAOF` pull everything back into memory, which can exceed the KV
budget. The AOF is the supported durability path in that mode.

## Why is `KEYS` blocking everything?

One executor means one command at a time. `KEYS` is O(N) over the whole keyspace,
so use `SCAN`, which is incremental. Read-only O(N) commands can be bounded with
`command-timeout-ms`, but that caps the stall rather than removing it.

## Does it support ACLs, modules, or Redis Functions?

No, no, and no. Authentication is `requirepass`, a single shared password; `AUTH`
takes one argument. Dynamic module loading and `FUNCTION` are absent. RedisTimeSeries
and RedisBloom are partially implemented as built-in types:
[data types](/data-types/).

## How do I run it in Docker?

`docker run -p 6379:6379 barddoo/zedis`, with Debian, Alpine, and distroless
variants. See [install and run](/getting-started/#docker).
