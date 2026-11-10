# Benchmark Comparison

Compared results from:

- `zedis-benchmark-matrix.txt`
- `valkey-benchmark-matrix.txt`

Valkey version used for comparison: `Valkey 9.0.3 (6e63ad9c/1) 64 bit`

Target in both cases: `127.0.0.1:6379`

Hardware used for these runs:

- CPU: `AMD Ryzen 9 7900X 12-Core Processor`
- Cores / Threads: `12 / 24`
- Max clock: `5.74 GHz`
- Cache: `L1d 384 KiB`, `L1i 384 KiB`, `L2 12 MiB`, `L3 64 MiB`
- RAM: `30 GiB`

## Throughput

| Case          |  Zedis SET | Valkey SET | Winner        |  Zedis GET | Valkey GET | Winner       |
| ------------- | ---------: | ---------: | ------------- | ---------: | ---------: | ------------ |
| Single client |  73,099.41 |  68,775.79 | Zedis +6.3%   |  73,855.24 |  66,844.91 | Zedis +10.5% |
| 50 clients    | 132,450.33 | 146,627.56 | Valkey +10.7% | 140,252.45 | 146,842.88 | Valkey +4.7% |
| 100 clients   | 145,985.41 | 145,560.41 | Zedis +0.3%   | 144,508.67 | 147,058.83 | Valkey +1.8% |
| 128B payload  | 134,228.19 | 147,929.00 | Valkey +10.2% | 144,508.67 | 146,198.83 | Valkey +1.2% |
| 1KB payload   | 132,978.73 | 140,845.08 | Valkey +5.9%  | 142,653.36 | 146,412.88 | Valkey +2.6% |

## p50 Latency

| Case          | Zedis SET | Valkey SET | Zedis GET | Valkey GET |
| ------------- | --------: | ---------: | --------: | ---------: |
| Single client |  0.015 ms |   0.015 ms |  0.015 ms |   0.015 ms |
| 50 clients    |  0.199 ms |   0.175 ms |  0.183 ms |   0.175 ms |
| 100 clients   |  0.351 ms |   0.351 ms |  0.351 ms |   0.351 ms |
| 128B payload  |  0.191 ms |   0.175 ms |  0.183 ms |   0.175 ms |
| 1KB payload   |  0.199 ms |   0.183 ms |  0.183 ms |   0.175 ms |

## Summary

- Zedis wins the single-client benchmark for both `SET` and `GET`.
- Valkey wins most multi-client and larger-payload cases.
- At `100` clients, `SET` throughput is nearly tied.

## Notes

- These numbers come directly from the two benchmark matrix output files in this repository.
- Results are sensitive to machine load, server build mode, and whether both servers were configured identically beyond the default port.

## TLS: Zedis vs Redis 8.10.3 (Apple M4)

Zedis built from the current tree with `zig build --release=fast` and OpenSSL
4.1.0 statically linked, against Redis `8.10.3` (Homebrew, OpenSSL 4.1.0).
Both listeners negotiated TLS 1.3 with `TLS_AES_256_GCM_SHA384` and used the
same self-signed certificate.

Hardware: Apple M4, 10 cores, 24 GiB RAM, macOS 27.0.1 (build 26A434).
Both servers ran on loopback with `port 0`, persistence disabled,
`maxmemory 0`, and `tls-auth-clients no`. Method: one warmup matrix, then
three measured matrices per server in alternating order, restarting the
servers between matrices; the table shows the median. Throughput values are
requests/second.

### TLS throughput

| Case          | Zedis SET | Redis SET | Zedis GET | Redis GET |
| ------------- | --------: | --------: | --------: | --------: |
| Single client |    31,075 |    13,920 |    31,526 |    14,526 |
| 50 clients    |   165,016 |   142,248 |   163,934 |   145,560 |
| 100 clients   |   166,667 |   169,492 |   167,224 |   173,913 |
| Pipeline x16  | 1,639,344 | 1,149,425 | 1,680,672 | 1,307,190 |
| 128B payload  |   164,474 |   140,252 |   164,745 |   146,199 |
| 1KB payload   |   159,490 |   134,590 |   158,228 |   142,045 |

### TLS p50 latency (ms)

| Case          | Zedis SET | Redis SET | Zedis GET | Redis GET |
| ------------- | --------: | --------: | --------: | --------: |
| Single client |     0.031 |     0.071 |     0.031 |     0.063 |
| 50 clients    |     0.175 |     0.279 |     0.183 |     0.271 |
| 100 clients   |     0.359 |     0.439 |     0.359 |     0.423 |
| Pipeline x16  |     0.375 |     0.527 |     0.367 |     0.447 |
| 128B payload  |     0.191 |     0.279 |     0.183 |     0.271 |
| 1KB payload   |     0.223 |     0.295 |     0.207 |     0.279 |

### TLS overhead vs the same server over plaintext

Same matrix run with TLS disabled (plaintext medians: Zedis ~210k-215k
requests/second at 50-100 clients and ~2.56M-2.74M pipelined; Redis
~185k-217k at 50-100 clients and ~1.60M-1.90M pipelined).

| Case          | Zedis SET | Redis SET | Zedis GET | Redis GET |
| ------------- | --------: | --------: | --------: | --------: |
| Single client |      8.6% |      8.6% |      6.8% |      4.2% |
| 50 clients    |     21.3% |     23.3% |     22.8% |     23.7% |
| 100 clients   |     21.5% |     21.9% |     22.6% |     20.0% |
| Pipeline x16  |     40.2% |     28.2% |     34.5% |     31.4% |
| 128B payload  |     23.4% |     23.0% |     23.7% |     22.8% |
| 1KB payload   |     24.7% |     27.5% |     25.3% |     23.7% |

### Summary

- Zedis wins single-client, 50-client, pipelined, and 128B/1KB cases over
  TLS. Redis is only 2-4% ahead at 100 clients.
- p50 latency is lower for Zedis in every multi-client case.
- Both servers now pay a similar TLS tax: roughly 21-28% in the
  non-pipelined multi-client cases. The pipelined case is higher for both
  because it is CPU-bound in the TLS record path.

### Caveats

- Client and server share the same machine, so `redis-benchmark` itself is
  a bottleneck in the pipelined and high-client cases. These numbers are
  valid for relative comparison, not as server ceilings.
- The run was measured with VS Code and OrbStack active on a 10-core
  machine (load average roughly 3). Both servers were affected equally.
- Verify negotiated protocol and cipher before repeating the comparison;
  a fallback to TLS 1.2 changes the result.

Run the matrix against a TLS listener with:

```bash
TLS=1 CACERT=/path/to/ca.crt scripts/redis-benchmark-matrix.sh
```
