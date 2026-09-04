# Llama Attention FPGA v3.1.4

这是面向 `XCZU15EG-FFVB1156-2-I` 的 Llama3 风格 Attention 加速器。当前硬件从 DDR 读取已经生成的 Q/K/V，完成 RoPE、QK、因果掩码、Online Softmax、与 V 融合和 Context 写回。

它不是完整的 Llama3-8B 推理系统：Embedding、RMSNorm、QKV/输出投影、MLP/SwiGLU、Residual、KV Cache、32 层调度、LM Head 和 Token 采样不在现有实现内。

## 当前状态（2026-09-02）

- 唯一活动目录：`03_work_v314_causal_bypass`；签核只读基线：`02_baseline_v313_verified`。
- v3.1.3 的 32 个生产 RTL 作为可追溯起点；当前分支只加入 v3.1.4 causal consumer bypass 及对应验证/软件计数。
- Host/Icarus 和 Vivado XSim 全部通过；full-GQA 模型通过误差阈值，但不是逐比特相等。
- A53 裸机源代码已用 Vitis 2025.2 编译通过。
- 本机缺少 XCZU15EG 的 Vivado synthesis 许可证，所以当前分支尚无匹配的综合、实现、Timing、BIT/XSA 或实板数据。

详细证据见 `WORKSPACE_STATUS.md` 和 `docs/NON_BOARD_RECOVERY_2026-09-02.md`；后续工作可按
`docs/STEP_BY_STEP_PROMPTS_CN.md` 中的提示词逐 Gate 推进。

## 目录

| 路径 | 内容 |
|---|---|
| `rtl/board/` | 板级顶层、AXI、DDR 读写和调度 |
| `rtl/core/` | Attention 计算主线 |
| `tb/`, `tests/` | RTL 单元/集成 TB 与回归入口 |
| `scripts/` | Vivado、Vitis、上板 Tcl 和生产清单 |
| `python/` | 数值模型、Golden 和日志分析 |
| `vitis/` | A53 裸机测试程序及板测数据 |
| `mem/`, `bd_base/` | LUT 初始化和 Zynq PS Block Design |
| `archive/` | 旧版追溯资料，只读，不进入生产工程 |
| `reports/`, `export/` | 生成报告和 BIT/XSA，不作为源码提交 |

生产层级为：

```text
attention_board_top
├─ design_1_wrapper
├─ aq_axi_master_fixed
└─ fpt_attention_board_engine
   ├─ Q/K/V DDR readers
   ├─ flash_attention_system_with_rope_top
   │  └─ RoPE → QK → causal metadata → Online Softmax → Context
   └─ fpt_context_ddr_writer
```

板级入口是 `rtl/board/attention_board_top.sv`。完整生产文件清单是 `scripts/source_manifest.tcl`；新增生产 RTL 必须显式加入。

## Windows 验证与构建

使用 Vivado/Vitis 2025.2。安装器生成的 `settings64.bat` 若引用已删除的 DocNav 路径，可直接调用各自目录下的 `.settings64-Vivado.bat` 和 `.settings64-Vitis.bat`。

```powershell
# Host/Icarus + Python 完整回归
powershell -ExecutionPolicy Bypass -File .\tests\run_v313_qk4_system_checks.ps1

# Consumer 定向 XSim（含 v3.1.4 bypass）
powershell -ExecutionPolicy Bypass -File .\tests\run_v31_flash_consumer_vivado.ps1 `
  -VivadoRoot D:\Vitis\2025.2\Vivado
```

有有效 synthesis/device 许可证后依次运行：

```bat
01_check_rtl.bat
02_build_bitstream.bat
03_build_vitis.bat
```

生成工程默认位于源码目录旁的 `_fpt_v314_build/`。可用 `FPT_VIVADO_BUILD_ROOT`、`FPT_XSA_OVERRIDE` 和 `FPT_VITIS_WORKSPACE` 指向短路径或临时验证目录。

## 修改规则

1. 不修改 `02_baseline_v313_verified`，不从 `archive/` 直接引用 RTL。
2. 每项优化使用独立分支和独立计数/正确性门禁；一次合并一个可归因改动。
3. RTL 变更先跑相关 TB，再跑完整 host 回归和 XSim；端口/层级变化后补 Elaboration/OOC synthesis。
4. 上板结果必须使用同一次构建的 BIT/XSA/ELF，记录 SHA-256、Vivado/Vitis 版本和 warm-up + 10-run UART 日志。
5. 论文只陈述已有证据；预测值、模型值、仿真值和板测值必须分开标注。
