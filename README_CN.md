# Llama Attention FPGA

这是 Llama3 风格 Attention 层的 FPGA 实现，目标器件为
`XCZU15EG-FFVB1156-2-I`。当前工程处理 DDR 中已经生成的 Q、K、V，
完成 RoPE、QK、因果掩码、在线 Softmax、与 V 融合以及 Context 写回。

它还不是完整的 Llama3-8B 推理系统。Embedding、RMSNorm、QKV/输出投影、
MLP/SwiGLU、Residual、KV Cache、32层调度、LM Head 和 Token 采样尚未实现。

## 当前状态（2026-08-30）

- 当前生产主线：32个 RTL 文件、33个模块。
- 当前回归：13个 SystemVerilog TB；Mac 端 Icarus 和 Python 数值回归通过。
- 历史发布包曾通过 XCZU15EG 实板验证。
- 当前 `unsigned_restoring_divider.sv` 与历史发布版不同；修改版已经通过
  Icarus 测试，但尚未重新完成 Vivado 2025.2 全流程和实板验证。
- 因此当前源码不能宣称与历史 BIT/XSA 完全一致。

## 目录

| 路径 | 内容 | 是否日常修改 |
|---|---|---|
| `rtl/board/` | 板级顶层、AXI、DDR读写和调度 | 板级接口变化时修改 |
| `rtl/core/` | 当前 Attention 计算主线 | 算法/架构开发主要修改处 |
| `tb/` | 当前 RTL 单元和集成测试 | 修改 RTL 时同步增加测试 |
| `tests/` | PowerShell/Vivado 测试入口和 Stub | 一般只运行 |
| `scripts/` | Vivado、Vitis、上板 Tcl | 工具链或板卡变化时修改 |
| `mem/` | RoPE 和指数 LUT 初始化文件 | 改算法/量化格式时生成 |
| `bd_base/` | Zynq PS、DDR、时钟 Block Design | 换板或改 PS 配置时修改 |
| `python/` | 数值模型、Golden 数据和日志分析 | 算法验证时修改 |
| `vitis/` | ARM 端上板测试程序和输入/Golden 数据 | 上板测试时修改 |
| `archive/` | 原始发布包和旧版 RTL/TB | 只读参考，不加入工程 |
| `reports/` | 验证报告；脚本可重新生成 | 不手工维护结果文件 |
| `export/` | Vivado 构建后生成的 XSA | 生成目录，目前可不存在 |

## RTL 连接关系

```text
attention_board_top
├─ design_1_wrapper                 Zynq PS / DDR / 时钟（由 BD 生成）
├─ aq_axi_master_fixed              PL 侧 AXI Master
└─ fpt_attention_board_engine       板级调度
   ├─ fpt_raw_qk_ddr_reader         读取 Q/K
   ├─ fpt_v_ddr_loader              读取 V
   ├─ flash_attention_system_with_rope_top
   │  └─ rope_qk_flash_attention_pipeline_top
   │     ├─ RoPE
   │     └─ qk_flash_attention_pipeline_top
   │        ├─ QK 脉动阵列和因果跳过/掩码
   │        └─ flash_attention_consumer_top
   │           ├─ Online Softmax
   │           ├─ V Cache
   │           └─ Context Fusion
   └─ fpt_context_ddr_writer        写回 Context
```

板级入口是 `rtl/board/attention_board_top.sv`。Vivado 使用的完整生产文件
清单在 `scripts/source_manifest.tcl`，新增生产 RTL 后必须显式加入该清单。

当前因果掩码不是一个独立顶层：完整无效 Tile 在 QK 阵列处跳过，Tile 内
无效元素由 `qk_flash_attention_pipeline_top.sv` 生成 mask 元数据。

## 在 Windows 上验证和构建

建议使用 Vivado/Vitis 2025.2，并先执行对应的 `settings64.bat`。

1. 运行当前仿真和数值回归：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tests\run_v313_qk4_system_checks.ps1
   ```

2. 只做整板 RTL Elaboration：

   ```bat
   01_check_rtl.bat
   ```

3. 综合、实现、生成 BIT/XSA：

   ```bat
   02_build_bitstream.bat
   ```

4. 构建 Vitis 裸机测试程序：

   ```bat
   03_build_vitis.bat
   ```

5. 上板前按 `scripts/run_on_board_no_gtr_xsct.tcl` 文件开头的说明提供
   `psu_init.tcl` 和应用 ELF。串口参数为 115200 8N1。

Vivado 的生成工程默认放在源码目录旁的 `_fpt_v313_build/`，不应提交或
复制回 `rtl/`。

## 修改规则

1. 改 RTL 前先确认它在 `scripts/source_manifest.tcl` 的生产清单中。
2. 每次 RTL 修改至少运行相关 TB，再运行完整系统检查。
3. 端口或层级变化后必须运行 `01_check_rtl.bat`。
4. 不要从 `archive/` 直接引用 RTL；需要恢复时先复制回生产目录并补测试。
5. 新增完整 Llama 模块时按功能新建清晰目录，不再使用 `a`、`bc` 这类历史命名。

## 尚未解决

1. 在 Vivado 2025.2 中重新完成 Elaboration、Synthesis、Implementation、
   Timing/DRC、Bitstream 和 XCZU15EG 实板验证。
2. 确认修改后的 `unsigned_restoring_divider.sv` 是否作为正式实现保留。
3. 将 `rtl/core/a`、`rtl/core/bc` 重命名为可读的功能目录；这要等 Vivado
   基线通过后再做，避免一次同时改变内容和路径。
4. 为完整 Llama3-8B 逐步增加线性层、RMSNorm、MLP、Residual、KV Cache、
   多层控制和 Token 输出链路。
