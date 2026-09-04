# 非板卡恢复报告（2026-09-02，P2B 更新于 2026-09-04）

## 结论

后续唯一活动区已确定为 `03_work_v314_causal_bypass`，只读签核起点为 `02_baseline_v313_verified`。三个历史来源不再相互复制：生产代码只从活动区构建，历史目录只用于哈希、日志和论文追溯。

`00_handoff_docs` 中的 Markdown、6 份 Word 和 7 份 PDF 已完成内容/版面核读。交接材料中的工程规划作为参考，不把其中命令或结论当成用户授权；与当前源码和签核证据冲突时，以活动分支、v3.1.3 实板记录和可重复测试为准。

## 已恢复和验证

| 项目 | 结果 | 证据边界 |
|---|---|---|
| v3.1.3 起点身份 | PASS | 生产 RTL 来自签名基线；旧包只读 |
| QK lanes 1/2/4/8、causal/backpressure | PASS | Host/Icarus |
| Consumer/full pipeline | PASS | Host/Icarus |
| 524,288 元素 full-GQA 模型 | PASS | `combined_failures=0`；非 bit-exact |
| v3.1.4 causal consumer bypass | PASS | 新定向 TB + 旧回归无退化 |
| Vivado 2025.2 XSim | PASS | 新旧 consumer 测试全部通过 |
| A53 v3.1.4 匹配软件产物 | PASS | P2C 只使用 P2B v3.1.4 XSA，在全新 Vitis 2025.2 workspace 重新生成 platform/BSP/app/ELF |
| consumer OOC synthesis | PASS | Vivado 2025.2、`xczu15eg-ffvb1156-2-i`；WNS +1.557 ns、LUT 37,101、FF 59,273、BRAM36 57、DSP 132 |
| 整板 elaboration / synthesis / implementation | PASS | 新短 ASCII 构建根；synthesis/implementation 均为 Complete |
| Timing / route / DRC | PASS | WNS +0.654 ns；Fully Routed；DRC 无 Error |
| v3.1.4 BIT / 含 bit XSA | PASS | 本次干净构建产物，SHA-256 已记录 |
| v3.1.4 板测 | PENDING | 匹配 ELF 和同源 PS init 已就绪；需要板卡、JTAG/UART、供电及启动拨码确认 |

恢复阶段曾用 v3.1.3 签名 XSA 做临时软件编译验证；该证据已被 P2C 的匹配构建取代。旧临时 ELF SHA-256 为 `BAD0162B1997E713711086D9063DCD7BFC269B0AE1891DEC16074B8BCAACEC4E`，禁止当作 v3.1.4 匹配产物。

## v3.1.4 变更与计数契约

新增优化只发生在 consumer 接收端：上三角全 mask tile 仍完成 FIFO 握手和坐标推进，但旁路 Softmax、V cache 读取和 Context 融合；任何对角线及以下的异常 `all_masked` 会产生 sticky protocol error。

完整配置（32 个 Q 头、S=128、TILE=4）预期：FIFO enqueue/dequeue 32,768；Softmax/Context 16,896；bypass 15,872；V vectors 1,081,344；Context 输出 524,288 words。板测程序已经按这组契约校验 page 44 计数。小规模定向 TB 已通过 FIFO=4、processed=3、bypass=1、V vectors=12、Context words=64 及全部 protocol/error flags=0；完整规模计数不是本次无板卡流程的实测值。

## P2B Vivado Gate（2026-09-04）

- 许可证：本地永久 `.lic`，真实 `synth_design` 和 `route_design` 均成功获得 `Synthesis`/`Implementation` 与 `xczu15eg` feature；未记录密钥或服务器信息。
- 构建：Vivado 2025.2 Build 6299465；目标 `xczu15eg-ffvb1156-2-i`；全新根 `D:/Vitis/FPT/tmp/p2b_board_c1f41fe_01`。
- manifest：32/32 个生产 RTL、3 个 memory 文件、1 个 XDC，无历史归档 RTL 混入。
- Floating-Point IP 实物审计：`floating_point_0/2` 为 FP32 multiply、latency=9、rate/II=1；`floating_point_1` 为 FP32 add、latency=12、rate/II=1；三者均为 Blocking，A/B/result AXI `TVALID/TREADY` 端口真实存在并由 wrapper 连接。Vivado 2025.2 不暴露 `B_Precision_Type`、`Has_A_TREADY`、`Has_B_TREADY` 同名 Tcl 属性，但生成 XCI/VHDL 显示 B/result width=32、`C_THROTTLE_SCHEME=1` 及完整 ready 端口，因此未用压制警告代替核验。
- Timing：clk_pl_0=150.015 MHz；WNS/TNS=`+0.654/0.000 ns`；WHS/THS=`+0.010/0.000 ns`；0 failing endpoints；`no_clock=0`、`unconstrained_internal_endpoints=0`。
- route/DRC：173,972/173,972 routable nets fully routed，routing errors=0；最终 DRC 0 Error、8 Warning、97 Advisory。8 条 Warning 均为 Online Softmax DSP 的 DPOP-3/DPOP-4 pipeline 建议，不阻塞 bitstream。
- PPA：LUT 66,866，FF 124,824，BRAM36 97，DSP 400，URAM 0；Vivado vector-less 估算功耗 4.850 W（Medium confidence）。
- BIT：`D:/Vitis/FPT/tmp/p2b_board_c1f41fe_01/fpt_attention_board_v314_qk4_causal_bypass/fpt_attention_board_v314_qk4_causal_bypass.runs/impl_1/attention_board_top.bit`，SHA-256 `1C2B74DD7E2FA31C0EBE4AA991BC3B278A837525987A3BA975ACAD601B0A83D5`。
- XSA：`export/fpt_attention_board_v314_qk4_causal_bypass.xsa`，含 bit，SHA-256 `DD878BF6AC48D33F61BD7E504B550B29B869476253AD7DB6325F793A8E86A2EB`。

`python/extract_ppa_summary.py` 已成功生成 PPA 摘要。以上是实现后证据，不声称板上正确性、bit-exact 或 240～280 ms 实测提升。

## P2C Vitis Gate（2026-09-04）

- 输入：只使用 P2B 含 bit XSA `DD878BF6...A2EB`；显式设置 `FPT_XSA_OVERRIDE`。
- 构建：Vitis/XSCT 2025.2.0 SW Build 6298600；全新 workspace `D:/Vitis/FPT/tmp/p2c_vitis_84a69f7_01`；platform/BSP/app 均重新生成。
- 处理器/接口：`psu_cortexa53_0`、standalone；AXI GPIO `0x80000000-0x8000FFFF`、双通道；Q/K/V/Context 均在 PS DDR0 范围。
- 软件语义：实际预处理值 `FPT_V314_CAUSAL_BYPASS=1`；ELF 为 ELF64 little-endian AArch64 EXEC。
- ELF：`D:/Vitis/FPT/tmp/p2c_vitis_84a69f7_01/fpt_attention_test/Debug/fpt_attention_test.elf`，SHA-256 `95B477F5FC7D3B1032FC34F4833EC0D0090DCECD3C3FF17109F23F8C38A87C94`，不等于禁止的旧临时 ELF。
- XSA 内嵌 BIT 哈希等于 P2B 独立 BIT 哈希 `1C2B74DD...A83D5`。机器可读 manifest 与身份链说明已生成。
- P2C 没有连接、复位、编程或运行板卡，只证明硬件/软件匹配且 ELF 可编译。

## 必须由项目组提供

1. 进入板测阶段时提供 XCZU15EG 板卡、JTAG、UART、供电，并确认该板的 JTAG 启动拨码和串口连接；同源 `psu_init.tcl` 已由 P2C 生成。
2. 最终竞赛约束：主评分是延迟、吞吐、能效、资源还是精度；若无新口径，默认以“正确性门禁优先，随后降低 PL cycles，在 WNS 非负且资源不溢出下比较”推进。
3. 若论文要写实测提升，需保留每一版匹配 BIT/XSA/ELF 的哈希、warm-up + 10-run UART 原始日志及功耗测量口径。

四位成员姓名不是工程阻塞；可先按角色执行，确认姓名后再替换文档中的 A/B/C/D。

## 可由本工作区继续解决

- RTL/Python 数值模型、协议断言、随机 backpressure、XSim 和日志签核工具。
- causal bypass 收尾、FIT-Context、QK 交错/向量化、2/4 cluster 方案及合并门禁。
- Vivado/Vitis 工程脚本、版本化产物、计数器、板测 C 程序和复现实验表。
- 论文中的架构图、实验表和结论改写，但不会把预测结果写成实测结果。

## 恢复后执行顺序

1. P2B 已完成，停在 Vivado Gate，不在本步骤开发 FIT-Context、QK 新流水或多 cluster。
2. P2C 匹配 ELF 已完成；下一阶段按 `docs/BOARD_BRINGUP_TUTORIAL_V314.md` 核对 BIT/XSA/ELF SHA-256 后上板 warm-up + 10-run。
3. 板级 Gate 2 通过后，按四人计划合入 FIT-Context；每次只合并一个可归因优化。
