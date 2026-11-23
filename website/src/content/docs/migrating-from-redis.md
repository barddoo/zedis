---
title: Migrating from Redis
description: What actually breaks when you point an existing Redis client at Zedis.
---

Zedis speaks RESP2 and RESP3, and 118 of the 167 commands in the
[compatibility matrix](/compatibility/) are fully implemented, so most clients
connect and most workloads run. This page is the list of things that do not
silently behave like Redis.

## Check these before you cut over

### There is only one database

Zedis keeps a single store. `SELECT 0` succeeds; any other index is rejected. A
client that pools connections per logical database, or that runs `SELECT 3` during
setup, will fail on connect. If your application separates tenants by database
number, namespace the keys instead.

### Expiry is lazy

There is no active expiry cycle. A key past its TTL stops being visible as soon as
anything touches it, and eviction prefers expired entries — but nothing walks the
keyspace to reclaim memory on its own.

In practice: a workload that writes many short-TTL keys and rarely reads them will
hold memory longer than the same workload on Redis. Size `maxmemory` with that in
mind, and prefer `volatile-lru` or `allkeys-lru` so expired capacity can be
reclaimed under pressure. With `noeviction` it simply stays.

### AUTH is password-only

`AUTH` takes a single password argument and checks it against `requirepass`. The
two-argument ACL form is not supported, there are no ACL users, and command
permissions are all-or-nothing. Isolate by network or TLS instead of by ACL.

### One executor, so one slow command stalls everything

Commands run on a single OS thread with no store lock, which is what makes it
fast — and what makes `KEYS` on a large keyspace a stop-the-world operation.
Use `SCAN`. Read-only O(N) commands can be bounded with `command-timeout-ms`, but
that limits the stall rather than eliminating it. `SAVE` is synchronous by design;
`BGSAVE` is not implemented.

### TLS 1.3 only

`tls-protocols` accepts `TLSv1.2` for config compatibility, but the engine never
negotiates it. Clients pinned to TLS 1.2 cannot connect. See
[configuration](/configuration/#tls-in-practice).

## What is not there at all

Replication, cluster mode, `WATCH`/`UNWATCH`, streams (`X*`), `BGSAVE`,
`MONITOR`, `LASTSAVE`, Redis Functions, ACLs, and dynamic module loading.
RediSearch handlers exist in the source but are not registered, so `FT.*` answers
with an unknown-command error. RedisTimeSeries and RedisBloom are partial: see
[data types](/data-types/).

## Compatibility snapshot

| Bucket           | Commands |
| ---------------- | -------- |
| Fully supported  | 118      |
| Partial          | 10       |
| Not implemented  | 39       |

That is roughly 77% of the 167 commands the matrix tracks. The
[full matrix](/compatibility/) has the per-command notes, including which
subcommands and options are missing on a "Yes" row.

## Migration checklist

1. Run your integration suite against Zedis on a spare port before touching
   production data.
2. Grep your client setup for `SELECT`, `CLIENT SETINFO`, `HELLO`, and `WATCH` —
   these are the four that most often fail at connect time or under concurrency.
3. Replace `WATCH`-based optimistic locking with `EVAL` scripts or application-level
   locking.
4. Audit TTL-heavy writes for memory growth, then set `maxmemory` and an eviction
   policy that matches your tolerance for loss.
5. Choose a durability story: `appendonly yes` for a recovery log, RDB snapshots
   otherwise. They are never mixed — see [persistence](/persistence/).
6. Point your scraper at `METRICS` and alert on the counters in
   [monitoring](/monitoring/).

## When something is missing

File an issue with the command and the error you got. The matrix is updated as
commands land, and a "No" row is a statement about today, not a rejection.
