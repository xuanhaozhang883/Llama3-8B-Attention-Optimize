# RTL 串行 Gate 复现入口

本目录的 RTL Gate 只服务于 `fpt_xczu15eg_attention/rtl/core` 这一份权威 RTL。
仿真结果和 Gate 证据进入 `fpt_xczu15eg_attention/build/rtl_gates/`；板级 Vivado
工程和 GUI 顶层日志进入 `FPT_VIVADO_BUILD_ROOT`。这些生成路径均不进入 Git 提交。

小规模仿真使用的 RoPE ROM 固定在 `tests/data/`；测试不会从旧工程目录或个人路径
读取 `.hex` 文件。

Gate 测试必须从**完整 Git 仓库 clone** 中运行。Gate 0 还复用仓库内受 Git 跟踪的
小规模 TB 和浮点行为模型；历史 v2.4 独立源码包不是 RTL Gate 交付物，不包含这两个
跨目录依赖。

## Gate 0：Legacy 基线闭环

最省操作的方式是双击：

```text
tests/run_gate0_vivado_gui.bat
```

它会打开 Vivado 2025.2 GUI 并自动运行完整 Gate 0。环境设置只对这一次 Vivado
进程生效，不会修改 Windows 的永久环境变量。默认生成工程位于
`%TEMP%/fpt_gate0/`；如已设置 `FPT_VIVADO_BUILD_ROOT`，则使用指定目录。

推荐从 Vivado 2025.2 GUI 的 **Tcl Console** 执行：

```tcl
cd {<clone-root>/fpt_xczu15eg_attention}
source {tests/run_gate0_legacy_closure.tcl}
```

脚本按固定顺序完成：

1. `tests/legacy_core_manifest.txt` 冻结的 44 个 v2.6 Legacy/并行 Core RTL 的小规模
   8-GQA 全链路 XSim；
2. 包结构、profiling 接口和样例日志的主机侧检查；
3. `xczu15eg-ffvb1156-2-i` 板级顶层 RTL elaboration。

如源码所在路径较长，可先在 Tcl Console 指定一个短的生成目录，再运行入口：

```tcl
set ::env(FPT_VIVADO_BUILD_ROOT) {D:/fpt_build/gate0}
source {tests/run_gate0_legacy_closure.tcl}
```

这个变量只改变 Vivado 生成工程的位置，不改变源文件。若手工启动时出现
`[Common 17-739] Failed to create user local XilinxTclStore`，可直接改用上述
`.bat` 入口。Gate 0 不使用在线 Tcl Store App；入口只对本次 GUI 设置
`XILINX_LOCAL_USER_DATA=NO` 和安装目录内的 `XILINX_TCLAPP_REPO`，不会重装
Vivado、修改安装目录或改变永久用户配置。

只有最后出现 `[PASS] GATE 0 LEGACY CLOSURE` 才算通过。主要结果位于：

```text
fpt_xczu15eg_attention/build/rtl_gates/gate0_legacy/
├── gate0_summary.json
├── gate0_closure_summary.json
├── compiled_sources.txt
├── GATE0_CLOSURE_PASS.txt
├── host_checks/
└── legacy_full_chain/
```

板级 Vivado 工程位于 `FPT_VIVADO_BUILD_ROOT`；脚本结束时会打印完整 `.xpr` 路径。
未设置该变量并从 Tcl Console 手工运行时，它默认落在上述 Gate 目录的
`board_elaboration/`；双击 `.bat` 时默认落在 `%TEMP%/fpt_gate0/`。

其中 `GATE0_CLOSURE_PASS.txt` 明确记录 `Board execution: NOT RUN`。目前没有实体板，
因此此 Gate 只能证明仿真正确和板级 RTL 可展开，不能宣称新提交已经上板通过。
`gate0_summary.json` 的 `SIM_PASS` 仅表示仿真通过；
`gate0_closure_summary.json` 的 `CLOSURE_PASS` 才表示仿真、主机检查和板级 RTL
展开全部通过。每次重跑都会先删除上一轮 PASS 证据，失败运行不会保留旧的通过标记。

双击 `.bat` 时，Vivado 顶层日志固定写入
`%FPT_VIVADO_BUILD_ROOT%/gate0_vivado.log` 和
`%FPT_VIVADO_BUILD_ROOT%/gate0_vivado.jou`，不会落到源码目录。

只希望快速重跑全链路 XSim 时，可执行：

```tcl
source {tests/run_gate0_legacy_regression.tcl}
```

快速入口不替代完整 Gate 关闭。

## 失败处理

- 不提交、不推送失败状态；
- 先查看 `legacy_full_chain/xvlog.log`、`xelab.log`、`xsim.log`；
- 板级错误查看脚本打印的 `FPT_VIVADO_BUILD_ROOT` 和 `.xpr` 路径；
- 修复后必须从完整入口重跑，不能只重跑失败的最后一步来生成 PASS 标记。
