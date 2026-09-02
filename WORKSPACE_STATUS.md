# 活动工程状态

这是唯一允许修改的后续工作目录。

## 来源策略

- 目录结构、显式 `scripts/source_manifest.tcl` 和精简测试入口来自 `Llama_on_FPGA`。
- 32 个生产 RTL 均与只读 v3.1.3 提交包 SHA-256 相同。
- `Llama_on_FPGA` 改写过的 `unsigned_restoring_divider.sv` 已恢复为签核提交包版本；该改写虽看似组合逻辑等价，但没有板级身份链，不作为起点。
- 提交包中 62 个旧架构 RTL、旧 TB 和发布打包脚本没有进入活动区；它们仍保存在只读基线中。

## 当前门禁

当前只是干净、可追踪的起点，不代表已经在本机复现 424.471607 ms。

2026-09-02 已完成 host 侧回归：QK lanes 1/2/4/8 等价、causal skip、随机 backpressure、FlashAttention consumer 集成、3 个 board-log signoff 单测和 full-GQA 524,288 元素数值模型均 PASS。数值模型得到 `combined_failures=0`，但有 223,988 个元素与 golden 逐比特不同，再次确认不能宣称 bit-exact。

开始改 causal bypass 前必须完成：

1. 补齐并核对 ELF、UART 日志、correctness JSON；
2. 确认 Vivado 2025.2、器件 `xczu15eg-ffvb1156-2-i` 和所有 Floating-Point IP 属性；
3. 运行 host/XSim 回归；
4. 用匹配的 BIT/XSA/ELF 完成 warm-up + 10-run；
5. 核对平均 63,669,978 PL cycles 和全部 tile/V/context counters。

本机发现 Vivado 2025.2 位于 `D:/Vitis/2025.2/Vivado/bin/vivado.bat`，但本次没有运行 `01_check_rtl.bat`。其项目创建 Tcl 会在 staging copy 上调用 `upgrade_ip`；按照 Gate 0 约束，应先完成基线身份/板测闭环，或另行明确允许后再运行。

## 第一项代码工作

基线闭环后只实施 consumer causal bypass：利用 FIFO 已有的 all-masked 元数据，推进握手/坐标/计数，但不启动 Softmax、V 读取和 Context 数据面。对角 tile 仍逐元素 mask，输出仍必须是 524,288 words。
