---
title: Monitoring
description: INFO counters, SLOWLOG, LATENCY, and scraping METRICS with Prometheus.
---

Zedis exposes four things: `INFO` for humans and Redis-compatible scrapers,
`SLOWLOG` for slow commands, `LATENCY` for spikes, and `METRICS` for Prometheus.

## INFO

`INFO` with no argument returns every section; pass a section name to narrow it.

| Section       | What it holds                                                        |
| ------------- | -------------------------------------------------------------------- |
| `server`      | Version, uptime, run mode, config file                               |
| `clients`     | Connected clients, blocked clients, `maxclients`                     |
| `memory`      | `used_memory`, `used_memory_disk`, `used_memory_total`, peak, budget |
| `persistence` | AOF enabled, size, pending bytes, last write/fsync result            |
| `stats`       | `instantaneous_ops_per_sec`, hits, misses, expired and evicted keys  |
| `commandstats`| Calls and time per command                                           |
| `keyspace`    | Key counts and expiry counts                                         |
| `replication` | Present for client compatibility; there is no replication            |

Field semantics worth knowing:

- `used_memory` counts in-memory store data only. With the disk tier on, add
  `used_memory_disk` for the total; `used_memory_total` is that sum.
- `keyspace_hits` / `keyspace_misses` drive a hit ratio that is the fastest signal
  for an undersized or mis-keyed cache.
- `evicted_keys` climbing steadily means the budget is too small for the working
  set; `expired_keys` climbing without `used_memory` falling means a TTL-heavy
  workload relying on lazy expiry.
- `used_memory_peak` is the high-water mark from the KV allocator, which is what
  you size alerting against.

## SLOWLOG

```conf
slowlog-log-slower-than 10000   # microseconds; -1 disables, 0 logs everything
slowlog-max-len 128             # entries kept in the ring
```

Every command is timed around execution, including commands run inside `EXEC`, and
`SLOWLOG` shares counters with `INFO commandstats`. `SLOWLOG GET`, `LEN`, and
`RESET` are implemented. Both limits are runtime-mutable:

```bash
redis-cli CONFIG SET slowlog-log-slower-than 5000
redis-cli SLOWLOG GET 10
```

## LATENCY

```conf
latency-monitor-threshold 0   # milliseconds; 0 disables the monitor
```

Set it to a value your p99 should never cross and `LATENCY LATEST` / `LATENCY
HISTORY` become the record of when it did. `LATENCY DOCTOR` summarizes; `RESET`
clears. Durations come from the monotonic clock, not the cached wall clock used
for TTLs.

## METRICS for Prometheus

`METRICS` renders the same counters as Prometheus text exposition, `zedis_`-prefixed:

```text
# TYPE zedis_ops_per_second gauge
zedis_ops_per_second 412880
# TYPE zedis_used_memory_bytes gauge
zedis_used_memory_bytes 41943040
# TYPE zedis_aof_last_write_ok gauge
zedis_aof_last_write_ok 1
```

Exposed series include uptime, connected clients, commands processed and failed,
ops/sec, net bytes, key counts, hits/misses and hit ratio, expired and evicted
keys, memory usage and peak, budget, AOF size/pending/last-write/fsync duration,
rewrites, and slowlog entries.

Scrape it with the Redis exporter off, using a small bridge script or an
`mget`-style endpoint. The simplest deployment is a cron/sidecar that runs
`redis-cli METRICS` and writes the output where Prometheus can read it:

```bash
while sleep 15; do
  redis-cli -p 6379 METRICS > /var/lib/node_exporter/textfile/zedis.prom.tmp \
    && mv /var/lib/node_exporter/textfile/zedis.prom.tmp \
          /var/lib/node_exporter/textfile/zedis.prom
done
```

`INFO` remains the source for `redis_exporter`-style scrapers that speak the Redis
protocol natively; you do not need both.
