# Benchmark results

Written by `make bench` (RUNS=5, SCALE=1, QUOTA=2s) on 2026-11-12.

## Machine

- CPU: Intel(R) Core(TM) i5-8257U CPU @ 1.40GHz, 8 logical cores
- Memory: 8 GiB
- OS: macOS 15.7.2
- Docker: 29.0.1, 8 CPUs, 4101144576 bytes
- OCaml: 4.14.2, dune --profile release

## Postgres

```
server_version = 16.4 (Debian 16.4-1.pgdg120+2)
checkpoint_timeout = 300 s
effective_io_concurrency = 1
fsync = on
full_page_writes = on
max_wal_size = 1024 MB
shared_buffers = 16384 8kB
synchronous_commit = on
wal_level = replica
work_mem = 4096 kB
```

## Data

```
((config
  ((seed 42) (events 10000000) (symbols 2000) (etfs 100) (basket_size 50)
   (etf_price_ratio 0.02) (rebalance_ratio 0.0001)
   (rebalance_step_ratio 0.01) (reject_ratio 0.1) (composition_ratio 5E-05)
   (volatility 0.0005) (tick_interval 100us)))
 (summary
  ((events 10000000) (prices 9747692) (etf_prices 200026) (compositions 607)
   (rebalance_steps 51675) (rebalances 1034) (rejected_rebalances 98)
   (symbols_held 1852) (mean_holders_per_symbol 2.6997840172786178)
   (max_holders_per_symbol 9))))
```

## Microbenchmarks

One step of each model on markets of 16 ETFs; see `bench/micro.ml`.

```
Estimated testing time 1m16s (38 benchmarks x 2s). Change using '-quota'.
                                                                                                   
  Name                                           Time/Run       mWd/Run     mjWd/Run     Prom/Run  
 -------------------------------------------- ------------ ------------- ------------ ------------ 
  tick basket:8 overlap:1 full                     1.11us       191.00w        0.20w        0.20w  
  tick basket:8 overlap:1 incremental              1.26us       130.00w        0.39w        0.39w  
  tick basket:8 overlap:4 full                     3.23us       561.37w        0.20w        0.20w  
  tick basket:8 overlap:4 incremental              7.32us       307.01w        0.71w        0.71w  
  tick basket:32 overlap:1 full                    9.51us       407.00w        1.65w        1.65w  
  tick basket:32 overlap:1 incremental             2.03us       134.00w        1.60w        1.60w  
  tick basket:32 overlap:4 full                   17.64us     1_425.37w        1.66w        1.66w  
  tick basket:32 overlap:4 incremental             7.48us       323.03w        2.90w        2.90w  
  tick basket:32 overlap:16 full                  63.39us     5_413.00w        3.27w        3.27w  
  tick basket:32 overlap:16 incremental           44.94us     1_151.68w        9.89w        9.89w  
  tick basket:128 overlap:1 full                  21.68us     1_271.00w        2.58w        2.58w  
  tick basket:128 overlap:1 incremental            2.82us       138.00w        6.03w        6.03w  
  tick basket:128 overlap:4 full                  63.96us     4_881.37w        4.54w        4.54w  
  tick basket:128 overlap:4 incremental           20.89us       339.16w       12.12w       12.12w  
  tick basket:128 overlap:16 full                271.90us    19_237.00w       14.56w       14.56w  
  tick basket:128 overlap:16 incremental         186.84us     1_231.34w       43.80w       43.80w  
  tick basket:512 overlap:1 full                  92.17us     4_214.00w      515.28w        2.28w  
  tick basket:512 overlap:1 incremental            3.32us       142.00w        6.04w        6.04w  
  tick basket:512 overlap:4 full                 328.99us    16_653.57w    2_055.52w        3.52w  
  tick basket:512 overlap:4 incremental           11.26us       355.08w       18.16w       18.16w  
  tick basket:512 overlap:16 full                900.47us    66_325.00w    8_227.06w       19.06w  
  tick basket:512 overlap:16 incremental          43.62us     1_281.62w       67.79w       67.79w  
  swap basket:8 overlap:1 full                     9.94us       964.00w        0.75w        0.75w  
  swap basket:8 overlap:1 incremental             15.11us     1_623.50w        7.19w        7.19w  
  swap basket:32 overlap:1 full                   36.26us     3_396.00w        8.93w        8.93w  
  swap basket:32 overlap:1 incremental            61.70us     5_838.49w      101.09w      101.09w  
  swap basket:128 overlap:1 full                 142.28us    13_291.99w      136.30w      136.30w  
  swap basket:128 overlap:1 incremental          266.52us    22_869.75w    1_597.96w    1_597.96w  
  swap basket:512 overlap:1 full               1_092.44us    51_062.00w    8_065.87w    6_526.87w  
  swap basket:512 overlap:1 incremental        2_332.52us    89_184.29w   51_987.91w   50_448.91w  
  all ticks basket:8 overlap:4 full               33.84us     4_387.00w        4.12w        4.12w  
  all ticks basket:8 overlap:4 incremental        55.32us     3_092.00w        8.64w        8.64w  
  all ticks basket:32 overlap:4 full             152.09us    15_523.00w       48.14w       48.14w  
  all ticks basket:32 overlap:4 incremental      235.57us     9_716.00w      106.57w      106.57w  
  all ticks basket:128 overlap:4 full            620.57us    60_067.00w      700.95w      700.95w  
  all ticks basket:128 overlap:4 incremental     986.33us    36_212.00w    1_603.91w    1_603.91w  
  all ticks basket:512 overlap:4 full          3_165.21us   230_035.00w   18_903.74w   10_695.74w  
  all ticks basket:512 overlap:4 incremental   7_963.65us   142_209.68w   25_275.00w   25_275.00w  
                                                                                                   
```

## Engine

5 runs of each, interleaved; median (min–max). Latency is per batch, from poll to write. Recomputes are position and sum nodes evaluated by the graph.

| Run | Events | Events/s | p50 | p99 | NAV updates | Recomputes | Statements/event |
|-----|--------|----------|-----|-----|-------------|------------|------------------|
| full, no writer, batch 1 | 10,000,000 | 71.4k (39.4k–92.0k) | 10 µs (8 µs–16 µs) | 49 µs (31 µs–97 µs) | 24,579,037 | – | – |
| full, no writer, batch 100 | 10,000,000 | 61.7k (39.6k–84.5k) | 1.24 ms (1.07 ms–1.90 ms) | 5.68 ms (2.29 ms–9.09 ms) | 24,579,037 | – | – |
| full, no writer, batch 1000 | 10,000,000 | 64.8k (43.9k–73.1k) | 12.58 ms (11.94 ms–14.53 ms) | 40.90 ms (30.32 ms–159.21 ms) | 24,579,037 | – | – |
| incremental, no writer, batch 1 | 10,000,000 | 117.1k (75.8k–155.8k) | 6 µs (4 µs–7 µs) | 27 µs (16 µs–52 µs) | 24,579,037 | 163,953,603 | – |
| incremental, no writer, batch 100 | 10,000,000 | 191.5k (122.9k–216.5k) | 388 µs (359 µs–539 µs) | 1.37 ms (1.09 ms–3.04 ms) | 9,169,842 | 125,850,637 | – |
| incremental, no writer, batch 1000 | 10,000,000 | 377.9k (324.3k–401.2k) | 1.83 ms (1.75 ms–2.13 ms) | 4.85 ms (4.04 ms–5.99 ms) | 1,000,000 | 57,650,294 | – |
| incremental, baseline writer, batch 1 | 2,000 | 105 (43–114) | 8.75 ms (7.85 ms–17.30 ms) | 23.86 ms (23.33 ms–123.73 ms) | 4,845 | 23,656 | 13.268 |
| incremental, optimized writer, batch 1 | 2,000 | 259 (114–281) | 3.44 ms (3.21 ms–7.05 ms) | 9.66 ms (8.75 ms–32.05 ms) | 4,845 | 23,656 | 2.928 |
| incremental, optimized writer, batch 100 | 200,000 | 10.1k (6.7k–10.8k) | 8.68 ms (8.58 ms–13.04 ms) | 25.33 ms (20.01 ms–37.19 ms) | 183,334 | 2,511,161 | 0.042 |
| incremental, optimized writer, batch 1000 | 1,000,000 | 33.2k (21.1k–38.7k) | 25.62 ms (22.56 ms–34.88 ms) | 87.18 ms (62.11 ms–239.94 ms) | 100,000 | 5,771,357 | 0.005 |
