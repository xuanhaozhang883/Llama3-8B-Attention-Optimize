# “现在可以做，但尚未完成”收尾说明

本文件对应上一版清单第五部分。

> Vivado 2019.2 兼容性修正：OOC fallback 现在通过
> `set_property -dict` 传入 `-mode out_of_context`，避免该版本把属性值
> 误解析为 `set_property` 自身的命令行选项。此修正只影响 TCL，不改变 RTL。

> v3 综合签核修正：Row Tile Buffer 的 payload 存储已隔离为独立的
> common-clock simple-dual-port BRAM 模块，并由一项 elastic 输出状态
> 显式吸收同步读延迟。该结构不再依赖 Vivado 从复杂 FSM 中识别 RAM；三个浮点 IP
> 关闭各自的 OOC checkpoint，使其参与顶层全局综合。签核脚本新增
> `black_box_cells=0` 检查，因此资源和时序报告不会再遗漏浮点 IP。

> P Buffer 资源修正：原来的宽 RAM 可变 16-bit 部分写入在 Artix-7
> 上被展开成 26 个 RAMB18。现在按 `PV_TILE` lane 拆成独立 16-bit
> RAM，并限制正式 `PV_TILE=2` 配置最多使用 4 个 RAMB primitive。

> Artix-7 OOC 临时时序约束补充 `HD.CLK_SRC=BUFGCTRL_X0Y0`，消除
> Vivado 2019.2 无法估计 OOC 时钟延迟/偏斜的警告。KV260 最终工程
> 仍必须用板级实际时钟位置替换该临时属性。

> v4 时序修正：用户提供的联合综合报告已确认 Row/P Buffer、BlackBox、
> 锁存器和多驱动检查全部通过，但 100 MHz WNS 为 `-9.695 ns`。最差
> `19.316 ns` 路径位于 Row Buffer BRAM 到 Softmax 的 BF16 转换/最大值比较；
> 另有 `18.532 ns` 的概率乘法/编码输出路径。v4 已用输入弹性寄存器、窄位宽
> 等价转换器和三段输出运算寄存器同时切断这两条路径。v4 的 13 项行为回归
> 随后全部通过，WNS 改善至 `-5.643 ns`，TNS 改善至 `-239.439 ns`，失败端点
> 降为 58 个。

> v5 时序修正：v4 的 50 条最差路径全部属于同一个 Softmax 锥——
> `proc_idx -> score_mem -> EXP 地址/查表 -> sum_exp`。v5 把它拆成“存储读、
> 地址计算、LUT、累加”四个寄存阶段，同时把 32 位 `integer` 地址临时量收窄为
> `SCORE_W+1` 位。v5 的功能回归和 100 MHz 综合仍须在 Vivado 2019.2 中确认。

| 原待办 | v3 中的完成内容 | 验证入口 |
|---|---|---|
| B+C 联合 RTL 综合 | 结构/资源签核通过；v4 报告定位剩余 EXP 长路径，v5 已完成四段寄存修正 | `run_synthesis_bc_pipeline.tcl` |
| 锁存器/多驱动/不可综合结构/超大寄存器阵列 | 综合脚本自动检查 `LD*`、`MDRV-1`、关键 Buffer 的 FF 数量，并输出 methodology/check_timing | 同上 |
| 临时资源报告 | 自动生成层次化 utilization、RAM、timing、DCP 和摘要 | `reports/bc_pipeline_artix7/` |
| Row Tile Buffer BRAM | 独立 SDP BRAM 模块；快速脚本要求 `512x17` 恰好映射为一个 RAMB | `run_synthesis_row_buffer.tcl`，随后运行完整综合 |
| P Buffer BRAM | 使用双 Bank、同步宽读 `ram_style=block` 模板；未推断 RAMB 时失败 | 同上 |
| EXP LUT 占用 | 自动统计 `u_exp_lut` 下的 LUT/分布式 ROM 单元 | `SYNTHESIS_AUDIT_SUMMARY.txt` |
| 运行中复位 | 覆盖 QK 活动、C 后端活动、PV 输出停顿三个复位点，并在复位后完整跑完 Group 7 | `run_vivado_bc_extended.tcl` |
| busy 时重复 group_start | 验证错误置位、活动 Group 不被替换、原 Group 正常完成 | 同上 |
| 非法 group_id | 正式 8 Group 的 3 位编码没有非法值；参数化为 7 Group 后用 ID 7 验证同一拒绝逻辑 | 同上 |
| 真实 V 存储/V Cache | 新增 `bf16_v_cache.sv`，实际预装并逐向量读出数据 | 同上 |
| Group 0～7 连续运行 | 新增 `gqa_group_controller.sv` 和系统 wrapper；一个 start 顺序完成八组 | 同上 |

## 两种综合顶层

`qk_softmax_pv_pipeline_top` 保留外部 V 请求/响应接口，是负责人 A
最终集成时最灵活的正式边界。它继续用小型 `xc7a35t` 做临时 OOC 综合。

`qk_softmax_pv_system_top` 内含完整 V-cache 和 8-Group 参考控制器。完整
V-cache 为 `8×128×128×16 = 2,097,152 bit`，超过 `xc7a35t` 的 BRAM 容量，
所以临时综合使用 `xc7a100t`：

```tcl
source run_synthesis_bc_system.tcl
```

这两个 Artix-7 结果都只用于检查 RTL、RAM 推断和临时资源/时序；KV260
最终签核仍需支持 XCK26 的 Vivado。

## 完成定义

本包把 RTL、testbench、自动判定和一键脚本全部补齐。用户报告已完成结构、
资源及 v4 功能签核，并把时序从 `-9.695 ns` 改善到 `-5.643 ns`；v5 已针对
剩余 50 条同源 EXP 路径完成第二轮流水化。由于生成环境没有 Vivado/XSim，
v5 的动态 PASS 和新综合报告必须在用户的 Vivado 2019.2 中生成；在 WNS
非负之前，100 MHz 仍不能标记为完成。
