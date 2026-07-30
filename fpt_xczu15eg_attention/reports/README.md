# 验证与实现报告

## v2.3 回退基线

`baseline_v2.3/` 保存 v2.3 实体板 10-run 和 PPA 汇总。

## v2.4 细粒度 Profiling

`profile_v2.4/` 包含：

- Vivado 2024.2 综合、实现、时序、DRC、功耗与资源报告；
- `v24_performance_runs.csv`：10 次正确性和延迟；
- `v24_hardware_profile_runs.csv`：基础及细粒度硬件计数器；
- `v24_board_test_summary.md`：解析器生成的板测摘要。

v2.4 实体板结果为 10/10 正确、10/10 确定性、Combined failures=0。
完整结论见 `../doc/V2_4_BOARD_PASS_RECORD.md`。
