---
title: Persistence
description: RDB snapshots and the append-only file — what is written, when it is fsynced, and what is loaded at startup.
---

Zedis has two durability paths: RDB snapshots and an append-only file (AOF). They
are never combined. **The AOF is the recovery log when `appendonly yes`;
otherwise the RDB snapshot is.** An AOF left over from an earlier run is ignored
while `appendonly` is `no`, and a snapshot is ignored while it is `yes`. Changing
the setting changes which file the next start reads.

## RDB snapshots

```conf
dir ./
dbfilename dump.rdb
rdb-write-buffer-size 256kb
```

`SAVE` writes a point-in-time snapshot synchronously: it stalls the server for the
duration, exactly like Redis. `BGSAVE` is not implemented, so there is no
fork-and-continue path and no background write to race with.

Loading a snapshot is also synchronous and happens before the listeners accept
connections.

## Append-only file

```conf
appendonly yes
appendfilename appendonly.aof
appendfsync everysec      # always | everysec | no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
```

Commands are queued for the AOF while they execute, under a spinlock, so AOF order
matches execution order. A dedicated writer thread does the file I/O and the
fsyncs; the event loop never touches the file.

| `appendfsync` | Guarantee                                                          |
| ------------- | ------------------------------------------------------------------ |
| `always`      | The client waits for its last logged command to be fsynced before the reply is written (group commit: one fsync covers everything queued while the previous one ran) |
| `everysec`    | At most one second of acknowledged writes is lost on power loss    |
| `no`          | The OS decides; fastest, and the least safe                        |

Under `always` the durability wait happens outside command execution, so it can
suspend the client coroutine without breaking the no-suspension invariant. A
failed fsync is treated as unrecoverable: unlike a failed write, it does not clear
on retry, because the kernel may drop the dirty pages and report a later fsync as
successful.

`BGREWRITEAOF` compacts the file. Rewrites trigger automatically once the AOF grows
by `auto-aof-rewrite-percentage` since the last rewrite and is at least
`auto-aof-rewrite-min-size` — the two defaults above mean "at 64 MB, or doubled
since the last rewrite".

## Loading at startup

The loader refuses to start rather than guess. Three options govern it; none are
in the sample `zedis.conf`, so these are the defaults:

```conf
aof-load-truncated yes        # tolerate a truncated tail (a crash mid-write)
aof-load-broken no            # refuse to load a corrupt AOF
aof-load-broken-max-size 4096 # bytes that may be skipped when repairing
```

A truncated tail is normal after a crash: the last command was never fully written.
A corrupt middle section is not, and `no` is what stops the server from silently
loading a partial dataset. If the AOF cannot be loaded safely, startup fails with
the reason in the log instead of serving incomplete data.

## Shutdown

`SHUTDOWN [NOSAVE|SAVE]`, `SIGINT` and `SIGTERM` all take the same path: stop
accepting connections, drain clients, drain the AOF queue, fsync unless
`appendfsync no`, close the file, then release the listeners. `NOSAVE` is the
default. `CONFIG REWRITE` persists runtime changes back to the config file, which
matters when you tuned `maxmemory` or the slowlog live.

## Interaction with the disk tier

With `disk-storage yes`, spilled values live in TidesDB and are materialized on
read. `SAVE`, `BGREWRITEAOF`, and any full-store iteration load every value back
into memory, which can exceed the KV budget. In that mode the AOF is the supported
durability path.

:::note[Source of truth]
The canonical copy of this page lives at `docs/memory-architecture.md` and
`zedis.conf` in the repository root, which describe the AOF writer thread and the
directives. Update both when the behaviour changes.
:::
