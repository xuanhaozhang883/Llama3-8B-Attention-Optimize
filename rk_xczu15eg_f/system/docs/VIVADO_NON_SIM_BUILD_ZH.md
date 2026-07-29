# Vivado 非仿真构建与 XSA 交付

本入口用于已经由 Block Design 脚本生成的两个 GUI 工程：

- `system/vx/ps_dma_loopback/rk_ps_dma_loopback.xpr`
- `system/vx/ps_attention/rk_ps_attention_single_gqa.xpr`

它只负责 IP 输出产品、综合、实现、bitstream、XSA 和静态报告，不会启动任何
行为仿真。工程器件必须精确等于 `xczu15eg-ffvb1156-2-i`，否则脚本立即失败。

## 两种构建模式

| 模式 | 会做什么 | 不会做什么 |
|---|---|---|
| `xsa` | 检查器件、保存 IP 状态、按需升级 IP、生成 IP/BD 输出产品、导出不含 bit 的 XSA | 不启动综合、实现、bitstream 或仿真 |
| `bitstream` | 完成 `xsa` 的准备工作，运行 `synth_1` 和 `impl_1` 至 `write_bitstream`，保存静态报告，复制 bit，导出 `-include_bit` XSA | 不启动仿真，不执行板上程序 |

`SOFTWARE_PASS` 仅表示 Vivado 工具链构建成功。上板验证前，状态始终是
`HARDWARE_PENDING`，不能据此宣称 DDR、DMA 或 Attention 已经通过硬件测试。

## 推荐操作：VS Code PowerShell

先生成轻量 XSA，不运行综合：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_dma_loopback `
  -BuildMode xsa
```

DMA 回环硬件准备完成后，生成完整 bitstream 和含 bit 的 XSA：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_dma_loopback `
  -BuildMode bitstream `
  -Jobs 4
```

Attention 工程的调用方式：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_attention `
  -BuildMode bitstream `
  -Jobs 4
```

默认会复用仍然有效的已完成 run。DMA 工程需要从头重建时可显式添加
`-ResetRuns`。这会重置 Vivado 的 `synth_1`/`impl_1` 生成结果，但不会删除
源码或 XPR：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_dma_loopback `
  -BuildMode bitstream `
  -ResetRuns
```

Attention 使用 Module Reference/OOC 综合。修改 Attention RTL 后，不要只重置
顶层 run；先重新运行 `create_ps_attention_project.tcl`。该脚本只重建自己管理的
`system/vx/ps_attention` 目录，从而保证所有 OOC checkpoint 与当前 RTL 一致。

只检查路径和最终参数、不启动 Vivado：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_dma_loopback `
  -BuildMode bitstream `
  -DryRun
```

如 Vivado 不在默认位置，可传入可执行文件或目录：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_dma_loopback `
  -BuildMode xsa `
  -VivadoBin 'D:\Vitis\2025.2\Vivado\bin\unwrapped\win64.o'
```

## Vivado GUI 中调用

1. 在 Vivado 2025.2 中打开目标 XPR。
2. 打开底部 **Tcl Console**。
3. 先给脚本设置参数，再执行：

```tcl
set argv [list \
  --mode bitstream \
  --out D:/Vitis/FPT/rope-qk-integration/rk_xczu15eg_f/system/generated/vivado_build/gui_run \
  --jobs 4 \
  --upgrade-ip 1 \
  --reset-runs 0]
source D:/Vitis/FPT/rope-qk-integration/rk_xczu15eg_f/system/scripts/build_system_project.tcl
```

GUI 中省略 `--xpr` 时，脚本使用当前打开的工程。如果传入 `--xpr`，它必须与
当前工程完全一致；脚本不会偷偷关闭另一个已打开的工程。

## 输出位置

默认目录：

```text
rk_xczu15eg_f/system/generated/vivado_build/<工程名>/
```

主要文件：

```text
status.json
build.log
vivado_console.log
artifacts/<工程名>.xsa
artifacts/<工程名>.bit               # 仅 bitstream 模式
reports/ip_status_before.rpt
reports/ip_status_after.rpt
reports/synthesis_run_status.txt      # 仅 bitstream 模式
reports/implementation_run_status.txt # 仅 bitstream 模式
reports/timing_summary.rpt            # 仅 bitstream 模式
reports/utilization_hierarchical.rpt  # 仅 bitstream 模式
reports/methodology.rpt               # 仅 bitstream 模式
reports/drc.rpt                       # 仅 bitstream 模式
```

`xsa` 模式会为四份实现后报告写入明确的
`*.NOT_GENERATED.txt` 标记，避免把“未运行实现”误判为“报告丢失”。

这些默认输出属于可再生文件，位于 Git 忽略目录。需要提交时，应先核对比赛或
仓库的大文件政策，再有选择地复制 XSA/bit 到正式交付区；不要把整个 Vivado
生成目录加入 Git。
