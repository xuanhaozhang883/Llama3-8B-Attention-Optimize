# CATS-R4 系统集成下一阶段任务清单

日期：2026-09-11
基线：`4fb3102`（`codex/cats-r4-local-integration`）

## 当前已闭合

- C 侧 32-lane PV accumulator candidate：512 product beats、四个 32-feature chunk、归一化写回和 output writer 单元回归通过。
- 真实 BF16 V-cache → product adapter → accumulator → context：512 key×feature-block、四 chunk、背压、顺序、row-last、lane-level Golden 和计数器回归通过。
- software-B replay → weight-slot memory → PV wrapper → release 回归通过。
- 真实 V-cache runner 已纳入 `tests/run_cats_r4_c_candidate_gate.ps1`。
- `.gitattributes` 已固定 RTL、脚本、文档、manifest 和数值文件为 LF；`tests/check_repository_hygiene.py` 通过。

上述都是 Icarus/candidate 证据，不等同 Vivado OOC、XSim、时序、板测或 B2 READY。

## P0：先冻结系统边界

| 任务 | 完成定义 | 依赖 | 责任 |
|---|---|---|---|
| single-cluster wrapper | 一个 wrapper 实例化 A/B2/C/PV/output，所有 row/token/epoch/slot 信号有唯一来源 | B2 IF_V3 契约 | 队长+C |
| B→C 接口契约 | weight FP32 raw bits、key/block/last、valid-ready、abort、epoch、异常计数和 release 条件逐字段冻结 | 无 | 队长+B+C |
| memory/weight-slot service | 写入、commit、announce、N+2 read、release、stale epoch、clear/drain 在 wrapper 内闭合 | wrapper | C |
| abort/drain/epoch/reset | reset/clear/abort 时无旧 token、无旧 response、无旧 output；outstanding 归零 | service | B+C |

门禁：契约表与 assertions 合入；single-cluster unit XSim 通过；stale/abort/reset counter 为 0（预期注入除外）。

## P1：并行接通数据路径

1. 将真实 B2 输出替换 software-B replay，保留同一 IF_V3 replay TB 作为协议回归。
2. 将 V-cache 真实 32-lane response 接入 product adapter；对每个 row 记录 product accepted、add commit、normalization writeback、context emit。
3. 将 context chunk 接入 `cats_r4_output_reorder_serializer`，检查 32 个 64-bit beat 的地址、feature order、row/tensor last。
4. 将 serializer 接入 `cats_r4_output_cdc` 和现有 DDR writer；禁止跨时钟域直连多位 payload。
5. 建立 A→模拟B→C→PV→output 端到端 runner：先比 token/order/capacity，再比 numeric Golden。

门禁：Icarus candidate gate、Vivado OOC、Vivado XSim、CDC、check_timing、WNS/TNS；任一层失败不得升级 READY。

## P2：系统级闭环

- system counter closure：把 candidate counters 映射到真实顶层计数源，定义 accepted/committed/emitted 的不变量。
- single-cluster 端到端 XSim：覆盖正常行、背压、slot 复用、stale epoch、abort、drain、reset、DDR backpressure。
- OOC：对 wrapper、weight slot service、PV adapter/accumulator、output CDC/writer 分别生成 checkpoint，并记录工具版本、约束、WNS/TNS、CDC 结果。
- 文档：更新 interface matrix、counter dictionary、release gate 和 source manifest 说明。

## P3：仓库 hygiene / hash 策略

- canonical numerical model 仍唯一为 `python/flash_attention_tile_model.py`；不得新增第二套 Golden 目录。
- `vitis/data/*.hex` 是冻结输入；`vitis/src/fpt_golden_vectors.h` 仅为派生 header，生成前后逐字节比较。
- 只提交源码、可复现 runner、带身份的 manifest/report；不提交 `.Xil`、Vivado/Vitis cache、无身份日志或临时 snapshot。
- 用户未跟踪的 `artifacts/raw_logs/`、交接文档暂不删除、不自动纳入提交。
- 每次跨平台 checkout 运行 `git ls-files --eol`、`git diff --check`、`python tests/check_repository_hygiene.py`，输入和派生文件分别记录 SHA-256。

## 推进顺序

当前不需要“只等 B 完成”。应先完成 P0/P1 的接口、wrapper、service、output/CDC 和模拟 B 端到端；真实 B2 稳定后替换 stimulus 并做差分验收。推荐顺序是：

1. 冻结接口契约和 counter dictionary；
2. single-cluster wrapper + memory/slot service；
3. abort/drain/epoch/reset assertions；
4. output reorder/CDC/DDR writer 集成；
5. A→模拟B→C→PV→output XSim；
6. B2 替换与真实 Golden 数值签核；
7. OOC/时序/CDC/板测 release gate。