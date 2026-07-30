# v2.3 XCZU15EG 实体板通过记录

## 配置

- 8 GQA Groups，32 Q Heads，8 KV Heads；
- SEQ_LEN=128，HEAD_DIM=128，BF16；
- 测量范围：START MMIO pulse 至 ST_DONE；
- Host Q/K/V load 和 cache flush 不计入加速器延迟；
- 预热 1 次，正式测量 10 次。

## 正确性

```text
Correct runs              : 10 / 10
Deterministic result runs : 10 / 10
Exact mismatches          : 225853 / 524288
Strict abs failures       : 7
Strict failures rescued   : 7
Combined failures         : 0
Maximum absolute error    : 0.000122070
Maximum BF16 distance     : 1 ULP
Error detail bitmap       : 0x00000000
```

判定标准：

```text
abs_error <= 1e-4 OR BF16_distance <= 1 ULP
```

## 性能

```text
Minimum latency     : 1843.688 ms
Average latency     : 1843.689 ms
Maximum latency     : 1843.689 ms
Peak-to-peak jitter : 0.001 ms
Total PL cycles     : 276550520
Inferred PL clock   : 149.998 MHz
Effective QK+PV     : 0.1456 GFLOP/s
B+C busy            : 156648602 cycles
Real PV busy        : 119799808 cycles
```

## 结论

v2.3 完整 8 Group 硬件 Profiling 和 10-run Benchmark 在 XCZU15EG 实体板上通过。结果满足组合误差判据，但不是 bit-exact。

原始证据：`../logs/v2.3_hardware_profile_10run.txt`。
