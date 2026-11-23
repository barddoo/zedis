---
title: "Configuration"
description: "Every directive Zedis reads, with the built-in defaults and what each one costs."
---

Zedis reads a single config file, passed as the only argument:
`zedis /path/to/zedis.conf`. Values below are the built-in defaults.

Directives Zedis does not implement are ignored rather than rejected, so a config
written for Redis or Valkey loads but mostly does nothing. Stick to the keys on
this page.

:::caution[Restart-required settings]
Listeners, the data directory, and the fixed-size pools (`maxclients`,
`max-channels`, `initial-capacity`) are read at startup only. `maxmemory`,
`maxmemory-policy`, the `slowlog-*` limits, `latency-monitor-threshold` and
`command-timeout-ms` are runtime-mutable with `CONFIG SET`, and `CONFIG REWRITE`
persists them back to this file.
:::

## Network

```ini
# Interface to listen on. A list is accepted (`bind 127.0.0.1 -::1`) and the
# first address is used.
bind 127.0.0.1

port 6379

# Close a connection after it is idle for this many seconds. 0 disables.
timeout 0
```

## TLS

```ini
# TLS is disabled while tls-port is 0. When enabled, tls-cert-file and
# tls-key-file are required. Set `port 0` to serve TLS only.
#
# tls-port 6380
# tls-cert-file /etc/zedis/server.crt
# tls-key-file /etc/zedis/server.key
#
# Clients must present a certificate signed by this CA unless tls-auth-clients
# is `no` or `optional`.
# tls-ca-cert-file /etc/zedis/ca.crt
# tls-auth-clients yes
#
# Negotiated protocol versions. The TLS engine speaks TLS 1.3 only; TLSv1.2
# is accepted for Redis config compatibility but is not negotiated.
# tls-protocols "TLSv1.3"
```

## Memory

```ini
# The KV budget is 80% of the container's cgroup memory limit (Docker/
# Kubernetes) minus fixed overhead. Outside containers it defaults to 256 MB
# and a warning is logged. Set maxmemory to pin it; CONFIG SET maxmemory works
# at runtime. 0 means unlimited, like Redis. `kv-memory-budget` is an alias.
#
# maxmemory 2gb

# allkeys-lru | volatile-lru | noeviction
# noeviction rejects writes with -OOM once the budget cannot be freed.
maxmemory-policy allkeys-lru

# Candidates sampled per eviction.
maxmemory-samples 5

# Maximum concurrent client connections. Raising this raises fixed memory.
maxclients 10000

# Pub/sub limits. Raising these raises fixed memory.
max-channels 10000
max-subscribers-per-channel 1000

# Initial store hash-table capacity; reduces early rehashing.
initial-capacity 8192
```

## Snapshotting

```ini
# Working directory and filename for RDB snapshots.
dir ./
dbfilename dump.rdb

# Buffer used for RDB writes.
rdb-write-buffer-size 256kb
```

## Append only

```ini
appendonly no
appendfilename appendonly.aof

# always | everysec | no
appendfsync everysec
```

## Security

```ini
# requirepass changeme
```

## Observability

```ini
# Commands slower than this many microseconds are kept in SLOWLOG.
# -1 disables it; 0 logs every command.
slowlog-log-slower-than 10000

# Number of entries kept in the slow log.
slowlog-max-len 128

# Record a LATENCY event for commands slower than this many milliseconds.
# 0 disables the monitor.
latency-monitor-threshold 0

# Abort read-only O(N) commands (KEYS, LRANGE, SCAN COUNT, ...) that run
# longer than this many milliseconds. 0 disables the limit. Prefer SCAN over
# KEYS for large keyspaces; the timeout bounds a stall, it does not prevent it.
command-timeout-ms 0
```

## Runtime tuning

```ini
# Interval for the cached clock. 0 uses a realtime syscall per read (most
# accurate, higher CPU).
clock-update-ms 100

# Emit zio scheduler metrics every N seconds. 0 disables.
# scheduler-metrics-log-interval 0

# Coroutine stacks carved and committed at runtime init. 0 disables prewarming.
# stack-pool-prewarm 0
```

## TLS in practice

TLS is disabled while `tls-port` is `0`. Enable it with a certificate, key, and —
if clients must authenticate — a CA:

```ini
port 0                 # optional: serve TLS only
tls-port 6380
tls-cert-file /etc/zedis/server.crt
tls-key-file /etc/zedis/server.key
tls-ca-cert-file /etc/zedis/ca.crt
tls-auth-clients no    # yes (default), no, or optional
```

Then connect with any TLS-capable Redis client:

```bash
redis-cli --tls --insecure -p 6380
```

Drop `--insecure` once your client trusts the CA.

| `tls-auth-clients` | Behaviour                                                        |
| ------------------ | ---------------------------------------------------------------- |
| `yes` (default)    | Client certificate required and must chain to `tls-ca-cert-file` |
| `optional`         | Certificate accepted if presented, but not required              |
| `no`               | Client certificates are not requested                            |

If `tls-auth-clients` stays `yes` while `tls-ca-cert-file` is unset, clients cannot
authenticate — set the CA, or switch the directive to `no`.

TLS comes from [ztls](https://github.com/lalinsky/ztls), which builds and links
AWS-LC, so no system TLS library is needed. The engine speaks TLS 1.3 only:
`tls-protocols` accepts both `TLSv1.3` and `TLSv1.2` for config compatibility with
Redis, but TLS 1.2 is never negotiated.
