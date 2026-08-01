# v3.0 当前状态（2026-07-31）

## 最终 Context bank 改造说明

Online Context 已拆成 16 个独立单写口 distributed-RAM bank，避免 Vivado 将二维
Context 数组视为一个 16 写口 3D RAM 并整体落入寄存器。该改造后的融合核心与
RoPE/QK/V-cache 端到端 Icarus 回归均通过。改造前的同算法版本已通过 Vivado
2025.2 双 XSim 与整板 RTL elaboration；改造后重跑 Vivado 时，本机用户
`XilinxTclStore` 损坏，`xilinx::xsim` Tcl app 无法加载，因此状态不升级为最终
Vivado banked rerun PASS。修复 Tcl Store 后必须执行 README 中的 GUI 回归脚本。

- Online Softmax + Streaming Context RTL：完成。
- 完整 P 保存/重放与独立 PV：已从默认 Online hierarchy 删除。
- `ONLINE_MODE=0/1` Legacy/Online 双模式：完成，默认 Online。
- Vivado 2025.2 单元 Golden XSim：PASS。
- Vivado 2025.2 两组端到端 RoPE/QK/V Cache/Online XSim：PASS。
- XCZU15EG 整板 RTL elaboration：PASS（0 error、0 critical warning）。
- 完整 synthesis/implementation：BLOCKED（本机缺少 XCZU15EG Synthesis license）。
- RK-XCZU15EG-F 实体板：NOT RUN。
- 完整 S128/D128 Online Golden：生成器已提供，尚待 NumPy 环境执行。

可发布状态为：

```text
OPEN_SIM_PASS / PRE_BANK_XSIM_PASS / PRE_BANK_RTL_ELAB_PASS /
FINAL_VIVADO_RERUN_BLOCKED_TCLSTORE / SYNTH_BLOCKED_LICENSE / BOARD_NOT_RUN
```

旧 `STATUS.md`、reports、bit/XSA 和板测日志属于 v2.x 历史证据，不能作为 v3.0
上板或时序闭环结论。
