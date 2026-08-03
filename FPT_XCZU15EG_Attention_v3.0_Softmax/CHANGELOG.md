# Changelog

## v3.0-online-softmax-exact-denominator-board-pass

- 对外发布名称更新为 `FPT_XCZU15EG_Attention_v3.0_Softmax`；为避免破坏既有构建链，RTL 模块、工程名及 Tcl 中的 `v26` 标识保持不变。
- 修复 Online Softmax 跨行状态/分母处理错误：首次板测 Context 全零、`Real PV busy=0`；第一次修复后仅剩 2 个超出 1 ULP 的点；精确分母修复后最终通过。
- Vivado 2024.2 完成综合、实现、时序、DRC、BIT 与 XSA 导出：WNS `+1.327 ns`、WHS `+0.010 ns`，DRC `0 Error / 0 Critical Warning`。
- XCZU15EG 实板完成 1 次预热和 10 次正式测试：正确性 `10/10`、确定性 `10/10`、Combined failures `0`、最大误差 `1 ULP`。
- 平均端到端加速器延迟 `429.393630 ms`，平均 PL 周期 `64,408,268`，推断 PL 时钟 `149.998 MHz`。
- 新增最终产物 `export/fpt_attention_board_v30_causal_dualtile.bit/.xsa`，并保留兼容的 v26 文件名。
- 新增原始实板记录 `logs/v3.0_online_softmax_exact_denom_10run_pass.txt` 和最终发布哈希记录。

## v2.6-causal-dualtile-board-pass

- 以
  `FPT_XCZU15EG_Attention_v2.5_pingpong_integration_source(1)(1).zip`
  为唯一基线，记录SHA-256；
- 保留v2.5跨Group Ping-Pong；
- 新增双4×4 QK调度器，使用单个RoPE Cache读口进行轮询供数；
- 新增Causal QK Whole-Tile Skip和Masked Tile补发；
- B+C输出宽度从TILE2提升为原生TILE4；
- 新增双Bank原生TILE4 P/V Buffer和双路V Bank；
- 新增双4×4 PV调度器；
- `pv_systolic_tile`增加逐行enable/first/last和动态输入结束；
- PV严格按`k<=row`逐行有效，共享流在`row_base+3`结束；
- 双QK和双PV结果流均恢复为v2.5外部顺序；
- 新增page 40～46及`V26_CAUSAL_CSV`；
- 增加架构调度、操作计数、地址映射和RTL结构静态检查；
- 默认150 MHz，不在本版提频。

### 2026-07-31 板测通过

- Vivado 2024.2 RTL elaboration通过（0 Critical Warnings）；
- 综合、实现、DRC、时序检查通过（WNS +0.801 ns, TNS 0）；
- LUT 35,184 (10.31%), DSP 267 (7.57%), BRAM ~175.5 Tile (23.59%)；
- bitstream/XSA及Vitis 2024.2应用构建通过；
- XCZU15EG预热1次、正式10次正确性回归：10/10正确 + 10/10确定；
- Combined failures=0, Causal error flags=0x00000000；
- 固定计数全部匹配：QK 2112/1984, PV 4227072/4161536, TILE4 4194304；
- 平均延迟430.002 ms，Total PL cycles 64.5M，相对v2.5加速2.66×，相对v2.3加速4.29×；
- B+C/Real-PV overlap 44.72%，有效算力0.624 GFLOP/s。

## v2.5-pingpong-integration-source

- 以 v2.4 profile counters 10/10板级通过版为唯一基线；
- 新增跨 GQA Group Ping-Pong 调度器；
- 新增两个完整 Group 的 TILE2→TILE4 P/V repack Bank；
- B+C Group ID 与 Real-PV Group ID 解耦；
- Context元数据改为绑定当前 Real-PV Group；
- 两个Bank采用同步简单双端口BRAM模板；
- 增加连续预取和最终向量 `feed_complete` 保护；
- 增加小参数非均匀反压自检Testbench和Vivado一键脚本；
- 修正 `01_check_v25_rtl.bat` 入口，使其调用
  `check_rtl_elaboration_ipfix.tcl`；Block Design 以 Global Synthesis
  重新生成，避免 AXI GPIO OOC 模块在 `synth_design -rtl` 中缺失；
- `01/02` 批处理统一通过 `call vivado.bat` 调用 Vivado，保证返回后继续
  执行退出码和 PASS/FAIL 检查；
- 本地开源RTL编译与行为仿真通过，观测到 B+C/PV overlap；
- 12个受保护的QK/Softmax/PV/B+C关键RTL文件与v2.4 SHA-256一致；
- 预计新增80个RAMB36，总BRAM约24.13%，低于25%保护线；
- 当前尚未完成Vivado完整elaboration、实现或XCZU15EG板测。

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

