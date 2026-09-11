# CATS-R4 IF_V3 Replay 集成交付（2026-09-11）

## 目的与边界

本交付把唯一 Golden 模型产生的软件 Softmax replay 接入 C 侧 `cats_r4_weight_slot_mem`，用于在硬件 B2 完成前冻结并验证 B→C 协议、slot 生命周期和 PV 读回路径。

Replay 是验证 stimulus，不是硬件 B2 的替代实现；manifest 明确标记 `REPLAY_ONLY_NOT_HARDWARE_B2`，不得据此宣称 B2 已完成或已通过板测。

## 唯一数据源

- Golden 数值模型：`python/flash_attention_tile_model.py`
- 既有数值 runner：`tests/run_v31_flash_numerical_model.ps1`
- 本交付 replay CLI：`--emit-cats-r4-if-v3-replay`
- replay schema：`cats-r4-if-v3-software-b-replay-v1`
- 固定参数：S=D=128、numeric mode=1、epoch=`0xa203`

每个 row 固定发出 128 个 weight beat。causal mask beat 的 FP32 payload 为 `+0`，`last` 只在 key 127 置位；提交 beat 携带 FP32 `sum` 与 `inv_sum`。

## 本次覆盖

集成平台 `tb/tb_cats_r4_if_v3_replay_integration.sv` 使用四个代表性 row：

| group | head | row | slot | 有效 causal score |
|---:|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 | 1 |
| 1 | 4 | 31 | 1 | 32 |
| 2 | 8 | 63 | 2 | 64 |
| 7 | 31 | 127 | 0 | 128 |

覆盖项目：

- A→软件 B replay→C 的完整写入、commit、PV announce、读回、release；
- 写入背压与 commit 背压；
- clear 中断半行并确认计数器归零；
- stale epoch 写入被拒绝并计入 `epoch_drop`；
- slot 0 在三 slot 配置下复用；
- 128 项 N+2 response 读回、token/mask/data 全量比对；
- `weight_wr_accept=512`、`weight_rd_request=512`、`weight_rd_response=512`、`row_commit_count=4`、`pv_row_count=4`、`weight_release_count=4`，错误计数为 0（`epoch_drop=1` 为预期注入）。

## 一键运行

在仓库根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_cats_r4_if_v3_replay_integration.ps1 -IcarusRoot C:\iverilog
```

脚本会在系统临时目录创建 replay 与仿真产物，不污染仓库。也可传入 `-OutputRoot <目录>` 保存本次可审计产物；目标目录必须不存在。

成功标志：

```text
[PASS] CATS-R4 IF_V3 software-B replay emitted
PASS: CATS-R4 A/software-B replay -> C IF_V3 weight lifecycle
[PASS] CATS-R4 IF_V3 replay integration
```

## 已知限制与后续门槛

1. 当前验证使用 Icarus；Vivado/XSim、综合、时序和板测尚未纳入本交付。
2. replay adapter 不得加入 `scripts/source_manifest.tcl`；硬件 B2 完成后应以真实 B2 输出替换 stimulus，并保留同一 IF_V3 TB 作为回归。
3. 在接入真实 B2 前，B/C 双方必须继续遵守冻结契约：FP32 raw bits、row/token/epoch、valid-ready、last、abort/clear、背压、异常计数器和 release outstanding 清零条件。
4. 下一阶段优先级：
   - B：实现真实 B2，并输出与 replay manifest 同 schema 的可比对日志；
   - C：把 slot memory 接入 C/PV wrapper，补充 Vivado OOC/时序检查；
   - A+C：建立 A→B2→C 端到端仿真，先比 token/顺序/容量，再比数值；
   - 队长：审核 manifest、删除不需要的候选 Golden/临时文件，保持唯一生产路径。

## 结论

在 B2 尚未完成的前提下，C 侧 IF_V3 的协议和 weight slot 生命周期已经有可重复的 software-B replay 回归；下一步不是“只等 B 完成”，而是并行推进 C/PV 集成和 A→模拟 B→C 端到端测试，待真实 B2 输出稳定后进行 stimulus 替换与差分验收。
