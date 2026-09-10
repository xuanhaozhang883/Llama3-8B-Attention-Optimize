# D3 前置消融交付索引

日期：2026-09-10

本目录包含两部分结论：

1. 已完成并复核的 `v3.1.3 -> v3.1.4 causal consumer bypass` 单变量消融；
2. 对 CATS-R4 D3 正式 `row vs online` 入口条件的 GitHub 审计。

主报告：`D3_PRE_ABLATION_REPORT_2026-09-10.md`

机器可读摘要：`D3_PRE_ABLATION_SUMMARY_2026-09-10.json`

哈希清单：`D3_ARTIFACT_HASH_MANIFEST_2026-09-10.json`

状态：旧版本 causal-bypass 消融 `PASS_WITH_LIMITATIONS`；CATS-R4 正式
row/online D3 `BLOCKED_AT_ENTRY_GATE`。

限制：本机当前没有可调用的 Icarus Verilog/Vivado，因此本轮重新执行了
Python full-GQA、签核器单测和板测原始日志复核；RTL/XSim/OOC 使用已有归档
证据，不冒充本轮复跑。首次系统回归因找不到 `iverilog` 而停止，其日志保留为
`v313_system_checks.log`。
