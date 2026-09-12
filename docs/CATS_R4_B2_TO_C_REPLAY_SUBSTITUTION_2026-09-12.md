# CATS-R4 B2 → C replay-stimulus substitution

**冻结日期：2026-09-12**

当前 single-cluster gate 使用 software-B replay，仅用于闭合 C/PV/output 的协议、顺序、容量和数值路径。它不得被标记为硬件 B2。

## 替换入口

B2 完成后，B2 adapter 必须提供与现有 IF_V3 完全相同的五类信息：

1. `weight_wr`：`epoch/group/global_q_head/row/slot_id/numeric_mode/key/mask/data/last/valid/ready`；
2. `row_commit`：同一 row token 加 `sum_fp32/inv_sum_fp32`；
3. epoch/abort：B2 在 drain、clear、reset 后不得继续产生旧 epoch token；
4. counter：`weight_wr_accept`、`row_commit_count`、`mode_error`、`numeric_error`；
5. 可复现 stimulus manifest：source SHA、B2 RTL SHA、epoch、row 数、weight 数和输入派生文件 hash。

## 替换步骤

- 保留 `tb_cats_r4_single_cluster_wrapper.sv` 的 C/PV/output checker、V-cache responder 和 writer checker；
- 将当前 testcase 的 software-B weight loop 替换为 B2 adapter instance；
- 让 B2 adapter 连接到 wrapper 的 `weight_wr_*` 与 `row_commit_*` 端口，不改变 C 侧 slot/PV/output 端口；
- 先跑单 row、单 feature block，再跑 128 key × 4 block，最后跑 4096 row full replay；
- 对每一级保存 counter snapshot，要求 `request == response`、`row_commit == pv_row == release`、无 stale output；
- 只有 B2 Accuracy full/stress RTL replay、OOC、PPA/WNS 和 counter closure 全部通过后，才把 runner 名称从 replay gate 改为 B2 gate。

## 禁止事项

- 不把 software-B replay 目录改名成 B2 输出；
- 不绕过 IF_V3 wrapper 直接把 B2 多位 payload 送进 C；
- 不因 Icarus PASS 宣称 B2 Accuracy 或 Vivado PASS；
- 不在 B2 source/manifest/hash 缺失时替换 Golden header。

## 当前状态

B2 仍缺 Accuracy FP32 exp、ordered FP32 sum/reciprocal、完整 524288 weight writes 和 XSim/OOC/PPA 证据，因此本替换仍是待执行入口。