# 活动工程状态

`03_work_v314_causal_bypass` 是后续唯一允许修改和提交的工程目录；`02_baseline_v313_verified` 是只读签核基线，其他三个来源目录只作追溯资料，不能直接混入生产清单。

## 已恢复的非板卡闭环（更新至 2026-09-04）

- 活动分支：`codex/v314-causal-bypass`；起点为带标签 `workspace-v313-gate0` 的 v3.1.3 文件级签名基线。
- Host/Icarus 完整回归通过：QK lanes 1/2/4/8、causal skip、随机 backpressure、consumer/full integration、board-log 单测和 524,288 元素 full-GQA 数值模型均 PASS。
- Vivado 2025.2 XSim 回归通过，包括新增的 v3.1.4 causal consumer bypass 定向测试。
- P2C Vitis Gate 已通过：只使用 P2B 本次导出的 v3.1.4 含 bit XSA，在全新短 ASCII workspace 中重新生成 platform、standalone BSP、A53 app 和匹配 ELF；恢复阶段借用的 v3.1.3 XSA/临时 ELF 均未使用。
- 数值模型 `combined_failures=0`，但有 223,988 个元素与 golden 逐比特不同；当前正确口径是误差阈值通过，不能宣称 bit-exact。
- P2B Vivado Gate 已通过：Vivado 2025.2 对 `xczu15eg-ffvb1156-2-i` 完成 consumer OOC、整板 elaboration、synthesis、implementation、route、Timing、DRC、BIT 和含 bit XSA 导出。
- 本次整板干净构建根为 `D:/Vitis/FPT/tmp/p2b_board_c1f41fe_01`；`source_manifest.tcl` 覆盖磁盘上全部 32 个生产 RTL，并纳入 3 个 memory 文件和 1 个 XDC。

## v3.1.4 已实现

consumer 在确认 `all_masked && col_tile > row_tile` 时只推进 FIFO/坐标/计数，不启动 Online Softmax、V 读取或 Context 数据面；对角 tile 仍逐元素 mask，最终输出总量保持 524,288 words。

完整 32Q、S=128、TILE=4 的计数契约：

| 计数 | v3.1.3 | v3.1.4 期望 |
|---|---:|---:|
| FIFO tile enqueue/dequeue | 32,768 | 32,768 |
| Softmax/Context tile | 32,768 | 16,896 |
| causal consumer bypass | 0 | 15,872 |
| V vectors | 2,097,152 | 1,081,344 |
| Context output words | 524,288 | 524,288 |

这些完整规模数值是由协议和循环边界推导的软件/板测契约；小规模定向 TB 已实测 FIFO enqueue/dequeue=4、Softmax/Context processed=3、bypass=1、V vectors=12、Context words=64，且错误标志为 0。完整规模计数仍须匹配板卡日志确认。

## P2B 实现后结果

- synthesis 与 implementation run 均为 Complete；路由状态为 Fully Routed，173,972 个可路由网络全部完成，routing errors=0。
- 150.015 MHz 实现后 WNS/TNS=`+0.654/0.000 ns`，WHS/THS=`+0.010/0.000 ns`；`no_clock=0`、`unconstrained_internal_endpoints=0`。外部 `error` 引脚仍有 1 条 no-output-delay 方法学提示，不属于未约束内部时钟或关键路径。
- LUT=66,866（19.59%）、FF=124,824（18.29%）、BRAM36=97（13.04%）、DSP=400（11.34%）、URAM=0；Vivado vector-less 估算功耗 4.850 W，置信度 Medium。
- 最终 DRC 无 Error；保留 8 条非阻塞 DSP pipeline Warning 和 97 条 Advisory，未为消警告改变数据面。
- BIT SHA-256：`1C2B74DD7E2FA31C0EBE4AA991BC3B278A837525987A3BA975ACAD601B0A83D5`。
- 含 bit XSA SHA-256：`DD878BF6AC48D33F61BD7E504B550B29B869476253AD7DB6325F793A8E86A2EB`。

这些只证明实现后的时序/PPA 与可生成硬件产物，不证明板上正确性，也不构成 240～280 ms 实测提升。

## P2C 硬件/软件身份链

- Vitis/XSCT 2025.2.0 SW Build 6298600；新 workspace：`D:/Vitis/FPT/tmp/p2c_vitis_84a69f7_01`，运行前不存在。
- platform/BSP/app 均由 `scripts/create_vitis_app_xsct.tcl` 重新生成，处理器为 `psu_cortexa53_0`，OS 为 standalone。
- 新 BSP 确认 AXI GPIO `0x80000000-0x8000FFFF`、双通道；Q/K/V/Context 地址均落在 PS DDR0 范围内。
- 实际预处理宏为 `FPT_V314_CAUSAL_BYPASS=1`；ELF 为 ELF64 AArch64。
- ELF SHA-256：`95B477F5FC7D3B1032FC34F4833EC0D0090DCECD3C3FF17109F23F8C38A87C94`，与恢复阶段禁止使用的临时 ELF 哈希不同。
- XSA 内嵌 BIT 的 SHA-256 与 P2B 独立 BIT 完全一致。完整记录见 `artifacts/P2C_ARTIFACT_MANIFEST_2026-09-04.json` 和 `docs/P2C_ARTIFACT_IDENTITY_CHAIN_2026-09-04.md`。
- 串口日志签核器已向后兼容识别 v3.1.4 `16896/15872/1081344` 和 v3.1.3 legacy `32768/0/2097152` consumer 计数，并通过单元测试。

这些只证明硬件与软件产物匹配且 ELF 可编译；P2C 没有连接或操作板卡，不证明上板正确性或性能提升。

## 当前剩余阻塞

许可证阻塞已解除，匹配 ELF 已在 P2C 完成。当前只剩板级 Gate：由项目组提供 XCZU15EG 板卡、JTAG、UART、供电并确认启动拨码/串口连接，按 `docs/BOARD_BRINGUP_TUTORIAL_V314.md` 完成板测。

## 下一项架构工作

P2B 已通过，但尚未完成板级 Gate 2；因此不把第二项高风险数据面改动并入主线。后续仍按既定顺序：匹配 ELF 与板测完成后，优先 FIT-Context 流水化，其次 QK 细粒度交错/向量化，再评估 2-cluster 和 4-cluster；四人边界见 `docs/TEAM_4_OPTIMIZATION_PLAN.md`。
