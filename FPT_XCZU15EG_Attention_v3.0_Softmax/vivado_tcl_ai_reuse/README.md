# Vivado Tcl AI 复用工具包（v3.0 发布 / v26 内部兼容）

本目录供 AI/Codex 和 Vivado Tcl Console 调用。包装脚本统一转发到 `../scripts/vivado_flow.tcl`，不会复制底层工程逻辑。

## 使用约定

1. 先阅读本文件和 `manifest.json`。
2. 按 `elaborate -> sim_online -> synth -> implement -> bitstream` 逐级验证，不要用 bitstream 构建代替低成本语法或仿真检查。
3. 只修改 RTL、约束、手写 Tcl、testbench 和必要的 MEM/HEX 源文件；不要编辑 `.runs`、`.gen`、`.cache`、`.sim` 或 `.Xil` 中的生成文件。
4. 推荐把生成工程放在源码目录之外；需要短路径时，在启动 Vivado 前设置：

   ```powershell
   $env:FPT_VIVADO_BUILD_ROOT = "C:/b26exact"
   $env:FPT_JOBS = "8"
   ```

5. bitstream 与 XSA 必须来自同一次构建；硬件修改后，Vitis 平台和 A53 应用需要基于新 XSA 重编译。
6. XCZU15EG 的综合和实现需要覆盖当前 Vivado 版本的有效许可证。许可证失败不能通过 Tcl 流程绕过。

### Vivado 2024.2 Windows 实测注意事项

- 本发布版已使用 Vivado 2024.2 完成 XCZU15EG 综合、实现、时序、DRC、BIT/XSA 导出和实板验证。许可证文件属于本机配置，不应加入源码包。
- Zynq PS IP 生成仍可能触及 Windows 260 字符路径限制。目录联接会被 Vivado 规范化回长路径；应使用真实的物理短路径源码副本和短构建目录。
- 若 `launch_runs` 因 Windows `rundef.js Access denied` 失败，使用 `../scripts/build_profile_foreground_ipfix.tcl`。它在一个 Vivado 前台进程中执行综合、布局布线和 bitstream，已在 XCZU15EG 上实测通过。
- 前台实现不关联 `impl_1`，因此 XSA 以 fixed platform 单独导出，匹配的 `.bit` 文件放在同一 `export/` 目录。

## Vivado Tcl Console 用法

```tcl
cd C:/lhm/2_Work/4_FPT/FPT_XCZU15EG_Attention_v3.0_Softmax
source vivado_tcl_ai_reuse/00_load_flow.tcl
fpt_vivado::run elaborate
fpt_vivado::run sim_online
fpt_vivado::run synth 8
fpt_vivado::run implement 8
fpt_vivado::run bitstream 8
fpt_vivado::run reports
```

也可以直接执行单步包装脚本：

```tcl
source vivado_tcl_ai_reuse/20_elaborate.tcl
source vivado_tcl_ai_reuse/30_sim_online.tcl
source vivado_tcl_ai_reuse/40_synthesize.tcl
source vivado_tcl_ai_reuse/50_implement.tcl
source vivado_tcl_ai_reuse/60_bitstream_xsa.tcl
source vivado_tcl_ai_reuse/70_export_reports.tcl
```

## 动作说明

| 动作 | 包装脚本 | 说明 |
|---|---|---|
| `create` | `10_create_project.tcl` | 重建外部 XPR、BD 和 IP |
| `elaborate` | `20_elaborate.tcl` | 重建后执行 XCZU15EG 整机 RTL elaboration |
| `sim_online` | `30_sim_online.tcl` | 运行性能、功能、背压和数值向量 XSIM 回归 |
| `synth` | `40_synthesize.tcl` | 重置并运行 `synth_1` |
| `implement` | `50_implement.tcl` | 必要时综合，然后运行到 `route_design` |
| `bitstream` | `60_bitstream_xsa.tcl` | 完整构建并导出同一次实现的 bitstream/XSA |
| `reports` | `70_export_reports.tcl` | 从已完成的 `impl_1` 导出利用率、时序、DRC 和功耗报告 |

Online Softmax 独立综合/布局布线代理验证使用：

- `../scripts/synth_softmax_ooc.tcl`
- `../scripts/implement_softmax_ooc.tcl`

代理验证可使用免额外器件授权的 XCZU3EG，但它不能替代 XCZU15EG 整机 implementation 和板级测试。
