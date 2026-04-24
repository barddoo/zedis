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

| Case | Zedis SET | Valkey SET | Winner | Zedis GET | Valkey GET | Winner |
|---|---:|---:|---|---:|---:|---|
| Single client | 73,099.41 | 68,775.79 | Zedis +6.3% | 73,855.24 | 66,844.91 | Zedis +10.5% |
| 50 clients | 132,450.33 | 146,627.56 | Valkey +10.7% | 140,252.45 | 146,842.88 | Valkey +4.7% |
| 100 clients | 145,985.41 | 145,560.41 | Zedis +0.3% | 144,508.67 | 147,058.83 | Valkey +1.8% |
| 128B payload | 134,228.19 | 147,929.00 | Valkey +10.2% | 144,508.67 | 146,198.83 | Valkey +1.2% |
| 1KB payload | 132,978.73 | 140,845.08 | Valkey +5.9% | 142,653.36 | 146,412.88 | Valkey +2.6% |

## p50 Latency

| Case | Zedis SET | Valkey SET | Zedis GET | Valkey GET |
|---|---:|---:|---:|---:|
| Single client | 0.015 ms | 0.015 ms | 0.015 ms | 0.015 ms |
| 50 clients | 0.199 ms | 0.175 ms | 0.183 ms | 0.175 ms |
| 100 clients | 0.351 ms | 0.351 ms | 0.351 ms | 0.351 ms |
| 128B payload | 0.191 ms | 0.175 ms | 0.183 ms | 0.175 ms |
| 1KB payload | 0.199 ms | 0.183 ms | 0.183 ms | 0.175 ms |

## Summary

- Zedis wins the single-client benchmark for both `SET` and `GET`.
- Valkey wins most multi-client and larger-payload cases.
- At `100` clients, `SET` throughput is nearly tied.

## Notes

- These numbers come directly from the two benchmark matrix output files in this repository.
- Results are sensitive to machine load, server build mode, and whether both servers were configured identically beyond the default port.
