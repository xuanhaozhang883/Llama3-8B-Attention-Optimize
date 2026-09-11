# CATS-R4 B2 Integration Request

状态：`A→B NORMAL PATH VERIFIED / SCHEME A FROZEN / IR-B2-006 PATCH READY`

Owner：成员 B；请求处理人：A、C、队长。

本文件只记录公共接口请求，不修改 A 的 QK/scheduler/cluster control、C 的
AXI/DMA/CDC/board top、D 的 golden/阈值/日志。

## IR-B2-001：A→B row score/max 交接（正常路径已解决）

A 分支 `agent/cats-r4-a2-row-handoff` 的提交
`d06d999a409a68dd89d1e4db8d78d3eb8f5574cb` 已实现并冻结 row descriptor 与
score stream：

```text
row:   valid/ready, T, row_max_bf16[15:0]
score: valid/ready, T, key[6:0], score_bf16[15:0], last
T:     epoch[15:0], group[2:0], global_q_head[4:0], row[6:0],
       slot_id[1:0], numeric_mode[1:0]
```

实际 A-owned 入口为
`rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv`，serializer 为
`rtl/core/bc/qk/cats_r4_qk_ab_handoff.sv`。B 在分支
`member-b-cats-r4-a2-integration` 上直接运行了：

```powershell
tests/run_cats_r4_qk_ab_handoff_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_row_abort_arbiter_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
```

四项均 PASS。正常路径实测闭合 4,096 row header、4,096 row transfer 和
264,192 causal score；score 严格为 `0..row`、`last` 仅在 `key=row`，row max
与 score 都位于 formatter 的 BF16 RNE 边界之后，stall 时 payload 保持稳定。

A 的实际 abort `error_code` 为 3 bit，不是先前讨论的 4 bit；当前编码 1=token/key
响应错误、2=非有限 score、3=numeric mode 错误。该宽度尚未写入 v3 公共接口，B
不会自行扩展或重编码。

A 的实际 owner 语义也已明确：最后一个 score 握手时 owner 从 A 转给 B，但槽只在
完整 token 的 `final_release` 握手后回到 FREE。B2 单测可以使用明确标注的下游/PV
stub 返回 final release；生产路径必须等 B3 最后输出接受且 outstanding=0，不能在
B2 `row_commit` 时提前释放。

## IR-B2-002：Compatibility 与 Accuracy weight 宽度（已由 v3 解决）

`CATS_R4_INTERFACE_V3_COMMIT` 已冻结统一 32-bit payload：Compatibility 的 BF16
放低 16 位且高 16 位为零，Accuracy 使用 FP32 raw bits。B 将消费该接口，不直接
修改 C memory wrapper 或公共 top。

## IR-B2-003：row completion 与 reciprocal（B→C 已由 v3 解决）

v3 已冻结 `row_commit valid/ready,T,sum_fp32[31:0],inv_sum_fp32[31:0]`，且只允许
在 128 项 weight 写完、数值合法后提交。Compatibility 内部 Q15 sum/Q30 reciprocal
仍按 B 契约计算，但公共 payload 按 v3 转为 FP32。A 提交 `d06d999` 已确认 score
slot 不在 `row_commit` 时释放；完整 token 的 `final_release` 必须等到 B3 最后输出被
接受且 outstanding=0 后返回。B2 单元回归只能使用明确标注的 PV/release stub，不能
把该 stub 结果写成 B3 或系统集成证明。

## IR-B2-004：正式候选数据（已解决身份与 schema）

原始历史文件已经恢复并由 B 的 adapter 校验：

```text
docs/architecture_study_20260905/row_candidates_full.json
docs/architecture_study_20260905/row_candidates_stress.json
```

报告 SHA-256 分别为 `1fe8cc632c0cef75d735ce9cd5f89778e1b5cf11d15f7a030555b04dc8d3dc86`
和 `85bd41563851eb98b743607a0078c639c97c4a708f5ef6ad2354d602e88fc60a`。
adapter 同时校验 schema、8 个输入 hash、不可变阈值及 `459/4096` 历史失败。
这些 JSON 只有聚合软件结果、没有逐行向量，因此不能替代当前 RTL full/stress 重放。

## IR-B2-005：数值/协议错误后的发布语义（方案 A 已冻结）

队长已冻结方案 A：B 必须在本地完成整行 staging，128 个 weight、sum 和 inv_sum
全部计算并验证通过后才能开始 `weight_wr`。必须完成 128 次 accepted write 后才能
发送一次 `row_commit`。错误必须在首次 C 写入前发现，因此错误行对 C 保持零次写入，
V3 不新增 `weight_abort`。

批准的逻辑容量为每 cluster：三槽 weight `3*128*32 bit=1536 B`，sum/inv_sum
`3*64 bit=24 B`，合计约 `1560 B/cluster`，token/valid/counter 元数据另计；1/2/4
cluster 分别约 1560/3120/6240 B。实际 BRAM/LUTRAM 只能由后续 OOC 报告确定。

B 当前的 `cats_r4_b2_weight_stager.sv` 按该决定实现：算术侧只写 causal key，masked
key 在发布时生成 `mask=1,data=0`；validated finalize 前不选择发布；发布固定为
key=0..127，最后一次 accepted write 后才进入 commit；commit 后仍保持 HELD，直到
完整 token 的后续 PV/final release。pre-publish 错误使用 B 本地 `row_error` 报告并
等待 slot release 或全局 clear，不向 C 发 abort。publish 开始后的内部不变量由
assertion/fatal 处理并要求全局 clear，不伪装成可恢复行错误。

## IR-B2-006：A abort 后 score slot ownership 释放（本地修复，待 A 接收）

A 的 `cats_r4_qk_row_assembler.sv` 与 `cats_r4_qk_ab_handoff.sv` 会产生并缓存
`row_abort`，但 `cats_r4_qk_slot_lifecycle.sv` 只有 reserve、最终 score handoff 和
final release 三类状态转移，没有 abort/cancel 输入。`cats_r4_qk_row_handoff_wrapper.sv`
也只把 abort 送到外部 arbiter，没有在 abort 握手时取消 owner=A 的 reservation。

因此在 row assembly 或 score read 阶段发生 token、lane、mode 或非有限 score 错误时，
外部虽能收到 abort，score slot 仍可能保持 owner=A，后续同槽 reserve 会持续反压，
只能依靠全局 clear 恢复。现有 wrapper TB 只覆盖正常 final release；没有覆盖
“abort 被接受后同一 slot 可重新 reserve”。

需要补充并冻结：

1. abort/cancel 对 owner=A 的精确状态转移和完整 token 匹配；
2. abort 与最终 score handoff 同周期竞争时的优先级；
3. abort payload stall 稳定、恰好一次释放及错误 counter；
4. 集成 TB：三个 slot 分别在 assembler abort、handoff abort 后可重新 reserve，且
   owner/error/epoch counter 闭合。

经队长接受该状态转移并授权生成独立 cherry-pick commit，B 集成分支
`member-b-cats-r4-a2-integration` 已在 A 提交 `d06d999` 之上形成窄范围提交
`a26cdc5ee64e12884fc9e529213ba6630202356b`：

- `cats_r4_qk_slot_lifecycle.sv` 新增 owner=A 的完整 token abort/cancel；
- abort 与同槽 final-score handoff 竞争时 abort 优先；
- `cats_r4_qk_row_handoff_wrapper.sv` 将外部 abort 接受与 owner cancel 原子化；
- 新增 `aborts` counter，非法/错误 token abort 仍进入 owner error；
- wrapper TB 覆盖 slot0 assembler mode abort、slot1 handoff nonfinite abort、
  slot2 handoff token abort，stall 后接受均回到 FREE 并可重新 reserve；
- lifecycle TB 覆盖 normal release、abort cancel 及同槽竞争优先级。

Icarus lifecycle、abort arbiter、A→B full workload 和 wrapper 均 PASS；A→B full
workload 保持 4,096 rows / 264,192 scores。正式 XSim 因本机没有已确认可用的
Vivado 2025.2 路径而未执行。提交未推送，必须由 A 审查/接收后，IR-B2-006 才能
标为团队基线 RESOLVED。

IR-B2-005 的架构阻塞已经解除。Accuracy exp、positive FP32 add、row reciprocal、
三槽 row core 与方案 A V3 wrapper 已有 RTL/模型证据；stored Q/K 的 4096 行整行
逐位回归和实际 A serializer→Accuracy 也已 PASS。

## IR-B2-007：共同 numeric-mode 选择与 stager 共享（队长已冻结；B 局部实现完成）

A 的 `cats_r4_qk_a2_row_pipeline.sv` 已在 `txn_start_valid/ready` 握手时锁存
`txn_numeric_mode`，并把锁存 mode 复制给后续 row/score。队长已选择资源优先的
方案 A：两个 arithmetic core 在 finalize 前仲裁到一套共享三槽 stager，禁止复制为
两套 stager。

B 已在不修改公共 top 的前提下实现局部封装
`rtl/core/bc/softmax/cats_r4_b2_shared_stager_v3_wrapper.sv`：row 接收时锁存每个
slot 的 mode 与完整 token ownership；score 始终按 slot 已锁存的 mode 路由；两个
`cats_r4_b2_locking_arbiter` 分别仲裁 weight/finalize，stall 时锁住选择，防止两个
core 同时覆盖同一 stager slot。该 wrapper 仅例化一个
`cats_r4_b2_weight_stager`，并有 mode/owner/epoch/一次性 release 断言和三 seed
随机 C-side backpressure/clear/counter-clear 回归。

公共 top 的 txn_start、C 实际 memory service、B3 后的 final release 和 clear 边界
仍由 A/C 接入；B 不直接修改这些模块。该架构决定已解除，但 B2 的 XSim/OOC 与
系统级门禁仍未满足，状态继续为 `NOT READY`。
