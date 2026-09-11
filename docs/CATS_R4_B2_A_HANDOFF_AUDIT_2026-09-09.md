# CATS-R4 B2 对 A2 row handoff 的消费审计（2026-09-09）

## 结论

- 当前阶段：`B2 整行 Softmax`。
- 当前状态：`NORMAL PATH AVAILABLE / ABORT PATCH READY / SCHEME A IN DEVELOPMENT / NOT READY`。
- B 集成分支：`member-b-cats-r4-a2-integration`。
- 分支 base：`d06d999a409a68dd89d1e4db8d78d3eb8f5574cb`。
- 当前已提交 HEAD：`a26cdc5ee64e12884fc9e529213ba6630202356b`。
- interface merge-base：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`。
- A-owned RTL 仅有队长明确接受并授权制作 cherry-pick commit 的 abort/cancel
  窄修复；没有修改生产 manifest、board top、golden 或阈值。

## 已消费的 A 接口

A 的 row/score 正常路径与 v3 token 对齐：

```text
T = epoch[15:0], group[2:0], global_q_head[4:0], row[6:0],
    slot_id[1:0], numeric_mode[1:0]
row   = valid/ready, T, row_max_bf16[15:0]
score = valid/ready, T, key[6:0], score_bf16[15:0], last
```

实际生产者路径：

- `rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_handoff_wrapper.sv`
- `rtl/core/bc/qk/cats_r4_qk_ab_handoff.sv`
- `rtl/core/bc/qk/cats_r4_qk_slot_lifecycle.sv`

正常路径确认：row header 在 score 前完成握手；score 按 `key=0..row`；`last` 仅在
`key=row`；score/max 位于 `1/sqrt(128)` scaling 后的 BF16 RNE 边界；模式由
transaction start 锁存；stall 时 token/payload 稳定。最后一个 score 握手只完成
A→B owner handoff，slot 必须等待完整 token 的 `final_release` 才能复用。

## 本机复核

以下命令在 A 提交 `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb` 上执行：

```powershell
tests/run_cats_r4_qk_ab_handoff_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_row_abort_arbiter_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
```

结果：四项 PASS。full A→B handoff 报告 rows=4,096、causal scores=264,192，
deterministic 与 random-backpressure/reset marker 均出现。以上只证明 A handoff，
不是 B Accuracy RTL、B→C weight slab、XSim/OOC 或整板结果。

## 源码发现与本地修复

原 A 提交中的 `cats_r4_qk_slot_lifecycle.sv` 没有 abort/cancel 状态转移；
assembler/handoff abort 只送到外部 `row_abort` arbiter，错误路径可能耗尽三个 slot。

用户授权后，本 B 集成分支对这个精确问题实施了窄范围修复：外部 abort transfer 与
owner=A cancel 原子发生，同槽 abort 优先于 final-score handoff，并增加 abort counter。
测试分别使用 slot0/1/2 覆盖 assembler mode abort、handoff nonfinite abort 和 handoff
token abort；stall 期间 payload/owner 稳定，接受后槽均为 FREE 且可重新 reserve。

修改文件：

- `rtl/core/bc/qk/cats_r4_qk_slot_lifecycle.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_handoff_wrapper.sv`
- `tb/tb_cats_r4_qk_slot_lifecycle.sv`
- `tb/tb_cats_r4_qk_row_handoff_wrapper.sv`

相关 Icarus lifecycle、abort arbiter、full A→B 和 wrapper 全部 PASS；正式 XSim 因
本机没有已确认可用的 Vivado 2025.2 可执行文件而保持 `NOT RUN`。修复已作为独立提交
`a26cdc5ee64e12884fc9e529213ba6630202356b` 保存、未推送，仍需 A 审查/cherry-pick 后
才能更新共同基线，详见 `IR-B2-006`。

`IR-B2-005` 已由队长冻结为方案 A：B 在首次 C 写入前 staging 并验证整行；错误行
对 C 零写，V3 不新增 `weight_abort`。本地 stager 已实现 3*128*32-bit weight 与三组
sum/inv 元数据，固定发布 128 项后再 commit，commit 后仍等待 final release。

## B2 当前可继续与不可声称的内容

可继续：基于真实 A 正常 row/score token 开发 B-owned ingress、Compatibility/Accuracy
运算单元和正常路径 TB。当前 Compatibility V3 适配层和方案 A stager 已有 Icarus
checkpoint；stager full 计数为 4,096 rows、264,192 valid staged weights、524,288
accepted C writes、4,096 commits 和 4,096 release-stub transfers。
另有直接实例化 `cats_r4_qk_ab_handoff.sv` 的 A2→B2 TB，实测 1 row、4 score、
4 staged valid weights、128 V3 writes 和 1 commit，A/B error 均为 0。

不可声称：Accuracy FP32 weight RTL、共同 transaction/mode wrapper、真实 C memory
集成、B3 release、XSim/OOC/PPA/WNS 或 B2 READY。上述 524,288/4,096 仅是 B2 stager
Icarus 单元计数，release 是明确的 stub，不是 C/B3/系统证明。B 仍停留在 B2，不进入 B3。
