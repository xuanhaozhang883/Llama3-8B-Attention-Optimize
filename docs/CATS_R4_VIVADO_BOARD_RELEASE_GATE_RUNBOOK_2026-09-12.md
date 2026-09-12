# CATS-R4 Vivado / board release gate runbook

**冻结日期：2026-09-12**

Icarus candidate gate 已覆盖协议和回放路径；以下 gate 必须在目标 Vivado 安装、part、IP catalog 和板级工程可用后执行。

## XSim

- 用与 candidate gate 相同的 source manifest，加入 single-cluster wrapper、reorder→CDC→DDR writer candidate 和 B2 adapter；
- 保存 Vivado 版本、part、source commit、B2 commit、stimulus manifest hash；
- 执行 reset、backpressure、abort/drain、stale epoch、normal full replay；
- 归档 `xvlog/xelab/xsim` log、波形索引和 counter snapshot。

## OOC / timing / CDC

- 对 PV product adapter、PV accumulator、reorder serializer、CDC FIFO、DDR writer 和 B2 wrapper 分别做 OOC；
- 保存 utilization、WNS、TNS、WHs、clock uncertainty、DSP/BRAM/URAM 使用量；
- 执行 `report_cdc`、`check_timing`、`report_methodology`，所有 critical warning 必须有签核；
- 检查 async reset、AXI ready/valid、FIFO gray pointer 和 output payload stable-under-stall。

## Board release

- 生成并关联 BIT/XSA/ELF hash；
- 运行单 row、满 row、随机 stall、abort/restart、epoch rollover smoke；
- 读取硬件 counter，核对 `weight_wr_accept`、`pv_row_count`、`output_beats_committed` 和 `weight_release_count`；
- 只有 XSim、OOC、timing、CDC、board smoke 全部有归档证据，才允许标记 release。

## 当前状态

本工作区未发现可用 Vivado 2025.2 `xvlog/xsim` 工具路径，因此这些 gate 尚未执行，不得标记为 PASS。