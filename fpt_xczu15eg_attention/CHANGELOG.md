# Changelog

## v2.4-profile-counters-board-pass

- 修复导入Block Design继承
  `C:/lhm/2_Work/pl_read_write_ps_ddr.gen/`旧生成路径的问题。
- Vivado生成工程、BD staging和IP output products改到相邻短目录
  `_fpt_v24_build`，源码目录无需移动。
- `check_rtl_elaboration.tcl`每次重建生成工程，防止旧wrapper污染。
- 新增BD/XCI路径重写、wrapper归属和静态包审计保护。
- 保持 v2.3 数据通路、调度和 page 0～26 软件 ABI 不变。
- GPIO profiling page 选择器由 5 bit 扩展为 6 bit，新增 page 27～39。
- 将内部 RoPE、QK、Mask/Reorder、Softmax、B+C replay、
  Capture/Repack 和 stall 信号逐层引出至板级计数器。
- 增加 B+C/PV overlap、Context transfer、core idle 和 inter-stage wait。
- A53 程序读取并打印 `HWPROF_FINE_CSV`。
- Python 解析器同时兼容旧 v2.3 日志和新 v2.4 细粒度日志。
- 增加 RTL/C/Python profiling 契约检查。
- Vivado 2024.2 RTL elaboration、综合、实现、DRC、Bitstream/XSA 完成；
- WNS +1.146 ns、TNS 0，LUT/FF/BRAM/DSP 为
  51,679 / 36,888 / 99.5 / 136；
- Vitis 2024.2 A53 应用构建、JTAG 编程和 ELF 下载完成；
- XCZU15EG 实体板预热 1 次、正式 10 次，正确与确定性均为 10/10；
- Combined failures 为 0，最大 BF16 距离 1 ULP；
- 平均延迟 1843.689 ms，平均 PL 周期 276,550,484；
- 观测到 B+C/PV overlap 为 0，Real-PV feed stall 占 41.802%，
  明确阶段2优先进行跨 Group 双缓冲。

## v2.3-board-profile

- 完成 XCZU15EG 完整 8 Group 实体板闭环验证。
- 增加硬件阶段、DDR、Group 和错误明细 Profiling 计数器。
- A53 测试程序增加 1 次预热、10 次正式测量与混合 BF16 误差判据。
- 实测 10/10 正确，平均延迟 1843.689 ms，Combined failures 为 0。
- 冻结 v2.3 为后续架构优化的回退基线。

## v2.0-8group
- RUN_GROUPS 从 1 扩展为 8。
- 完整 Head 配置从 4Q/1KV 扩展为 32Q/8KV。
- 生成 32×128×128 Q/Context 与 8×128×128 K/V BF16 数据。
- A53 比较 524288 项 Context，并打印 Group 进度与按 Head 失败统计。
- Tcl 工程名与 XSA 名称集中配置。
- 保留 v1.7 已验证的 TILE4 Context 重排与 no-GTR 下载流程。
