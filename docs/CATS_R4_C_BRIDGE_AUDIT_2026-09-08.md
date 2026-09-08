# C 侧 bridge 接口审计（2026-09-08）

审计对象：`rtl/core/cluster/cats_r4_qkv_axi_bank_bridge.sv`。
基线：`CATS_R4_INTERFACE_COMMIT`（IF_V1）和 `CATS_R4_INTERFACE_V3.md`。
结论：`LOCAL CHECKPOINT / NOT READY`，不得接入生产系统。

## 已从源码确认

- Q/K/V 请求和响应在 `core_clk` 端口暴露；response 没有 ready 信号。
- 请求流水使用 `p0/p1` 两级标记，设计意图是 N+2。
- AXI descriptor 具有 epoch、group、head、row-window、beat index 的连续性检查。
- descriptor completion 由 `done_valid/done_ready` 保持。
- Q 使用 4 banks，K/V 使用 32 banks；该映射仍需冻结文档逐项回归。

## 尚未证明或存在风险

1. `q_req_ready/k_req_ready/v_req_ready` 直接等于 `active_valid`；尚未证明 buffer 切换期间必为 0，也没有完整 EMPTY/FILLING/READY/ACTIVE 状态机证据。
2. 代码使用 XPM `READ_LATENCY_B(1)` 加自有 p0/p1 流水；N+2 必须用真实 Vivado/XPM 模型连续请求验证，不能由 mock 推断。
3. 当前模块没有 v3 weight slab、row_commit、pv_row、release 接口，不能声称已实现 Accuracy weight memory service。
4. 当前模块没有完整 CDC FIFO、epoch_drop、4 KiB burst split、短尾 descriptor 和 v3 counter 集合。
5. `protocol_error_sticky` 在错误后停止 endpoint；需确认 reset/abort 后旧 epoch completion 丢弃且计数，而不是仅清除 sticky 位。

## 进入 C2 前的证据

- protocol-only 正向/负向 TB：bank、active-write、epoch mismatch、reset/abort、短尾、4 KiB 边界、FIFO 满。
- 真实 XPM/Vivado 仿真或 OOC 报告：N+2、无回压、连续请求保序。
- counter 表：正常负载与负向测试分开；正常负载错误计数全部为 0。
- 完整 source/tool/log manifest，均绑定同一 interface tag。
