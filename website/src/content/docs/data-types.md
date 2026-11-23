---
title: Data types
description: What each key can hold, with the time series and Bloom filter commands in detail.
---

Every key holds exactly one value. `TYPE` reports which, and the core types map to
familiar Redis commands: strings and integers, lists, sets, hashes, and sorted
sets. Two more types are built in beyond core Redis — time series and Bloom
filters — and both implement only a subset of their Redis module surfaces.

| Type          | Create with                          | Notes                                     |
| ------------- | ------------------------------------ | ----------------------------------------- |
| string        | `SET`, `INCR`, `APPEND`              | Values up to 512 MB                       |
| list          | `LPUSH`, `RPUSH`, `LINSERT`          | Blocking variants obey the no-suspend rule |
| set           | `SADD`                               |                                           |
| hash          | `HSET`, `HINCRBY`                    |                                           |
| sorted set    | `ZADD`                               |                                           |
| time series   | `TS.CREATE`, `TS.ADD`                | Gorilla-compressed chunks                 |
| Bloom filter  | `BF.RESERVE`, `BF.INSERT`            | Scalable, error-rate bounded              |

Streams are not implemented, and a type cannot be converted in place — `SET` over a
list replaces it.

## Time series

Samples are `(timestamp, value)` pairs stored in Gorilla-compressed chunks, so a
monotonic series costs a fraction of its raw 8-byte-per-sample size.

```bash
# Keep 24h of samples
redis-cli TS.CREATE temp:kitchen RETENTION 86400000
redis-cli TS.ADD temp:kitchen 1735689600000 21.5
redis-cli TS.ADD temp:kitchen 1735689601000 21.8

# Latest sample
redis-cli TS.GET temp:kitchen

# Whole series aggregated into hourly averages
redis-cli TS.RANGE temp:kitchen - + AGGREGATION AVG 3600000
```

`TS.ADD` requires an explicit millisecond timestamp — there is no `*` shorthand, so
the client supplies the clock. `TS.RANGE` accepts `-` and `+` for the range ends,
plus `COUNT` and `AGGREGATION`; relative spans like `24h` are not parsed. A
duplicate timestamp follows the series' `DUPLICATE_POLICY` — `BLOCK` by default, or
`FIRST`, `LAST`, `MIN`, `MAX`, `SUM` set at `TS.CREATE` or passed per call.
`IGNORE` drops samples that would move the last value by less than a threshold, and
only applies to `LAST` with in-order samples.

Retention is a time span, not a count: samples older than `RETENTION` milliseconds
are dropped as new ones arrive. `TS.INCRBY` / `TS.DECRBY` update the latest sample
in place, which is the cheap counter pattern. Aggregators for `TS.RANGE` are
`AVG`, `SUM`, `MIN`, `MAX`, `RANGE`, `COUNT`, `FIRST`, `LAST`, `STD.P`, `STD.S`,
`VAR.P`, `VAR.S`.

Not implemented: `TS.MGET`, `TS.MADD`, `TS.MRANGE`, `TS.CREATERULE`,
`TS.DELETERULE`. There is no cross-series query, so tag-based lookup means keeping
your own index.

## Bloom filters

```bash
# 0.1% false positives at 1M items, growing by 2x per new filter
redis-cli BF.RESERVE seen:urls 0.001 1000000 EXPANSION 2
redis-cli BF.ADD seen:urls https://example.com/a
redis-cli BF.EXISTS seen:urls https://example.com/a   # 1
redis-cli BF.EXISTS seen:urls https://example.com/b   # 0
redis-cli BF.INFO seen:urls
```

`BF.RESERVE key error_rate capacity [EXPANSION n] [NONSCALING]` fixes the error
rate and the initial capacity. Scalable filters add a new sub-filter when capacity
is hit, growing by `EXPANSION` (default `2`); the error rate is tightened by half on
each new filter, so the advertised rate holds across the chain. With `NONSCALING`,
adding past capacity returns an error instead of growing.

Only `BF.INSERT` creates a filter implicitly, with an error rate of `0.01`, a
default capacity of `100`, and expansion `2` — pass `CAPACITY`/`ERROR` to override,
or `NOCREATE` to refuse creation. `BF.ADD` and `BF.MADD` require the key to exist
and answer with a key-not-found error otherwise. `BF.INFO` reports capacity,
allocated size, number of filters, items inserted, and expansion rate.

There is no delete and no counting: a false positive never goes away, `BF.SCANDUMP`
/ `BF.LOADCHUNK` are not implemented, and `CF.*` (counting filters) is absent. Use
these for "have I seen this", not for membership you must be able to revoke.
