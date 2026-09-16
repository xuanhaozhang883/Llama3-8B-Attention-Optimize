# v3.1 FlashAttention 实体板签核

- 原始串口日志：`D:\学习\FPT\logs\v314_board_20260908_224532.log`
- warm-up：PASS
- 正确运行：10 / 10
- 确定性运行：10 / 10
- Combined failures：0（每次）
- Total PL cycles（min/avg/max）：45467467 / 45467510 / 45467570
- v3.1.3 基线：63669978 cycles / 424.471607 ms @ 150 MHz
- 整机周期提升：28.588777%
- 至少 10% 性能门禁：PASS
- 规划延迟区间：240～280 ms（仅展示，不是 hard gate）

使用 consumer profile：v314-causal-bypass。固定硬件计数均逐次通过：QK 16896/15872、masked tile 15872、Flash Context processed/bypassed 16896/15872、V vector 1081344、Context word 524288，全部错误标志为 0。
