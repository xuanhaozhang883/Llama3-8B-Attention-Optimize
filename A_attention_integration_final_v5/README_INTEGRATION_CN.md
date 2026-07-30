# GQA 双缓冲优化交付审查、修正版与集成步骤

## 1. 先看结论

这两个队友交付包的总体方向正确，双 Bank 也是真实存在的；但原包不能不检查就直接合入主分支。

| 检查项 | 结论 |
| --- | --- |
| 两个完整 Group Bank | 已实现 |
| B+C 与 PV 跨 Group 并行 | 架构上已实现 |
| 性能/重复/缺失计数器 | 已实现 |
| 小规模验证报告 | 有，报告称通过 |
| 报告中列出的 3 个单元 TB | 原 zip 缺失，本修正版已补齐 |
| 完整链路 TB | 原 zip 缺失，必须使用主仓库中已经验证过的版本 |
| 启动握手 | 原版存在竞态，本修正版已修复 |
| 全尺寸综合、实现、上板 | 仍需重新执行，不能用仿真报告替代 |

原顶层把 Scheduler 的 `pv_start_ready` 只连接到 `!pv_busy`，却没有把双缓冲的 `drain_ready` 纳入同一次启动握手。前一个 PV 完成、Bank 尚未正式释放的边界周期内，可能出现 real-PV 已经接受启动而 Buffer 拒绝 `drain_start` 的情况。

修正版采用以下原则：

1. 先锁存准备启动的 Group ID 和 Bank ID。
2. `B+C ready` 与 `fill_ready` 同时为 1 时，才同时发出 `bc_group_start` 和 `fill_start`。
3. `!pv_busy` 与 `drain_ready` 同时为 1 时，才同时发出 `pv_start` 和 `drain_start`。
4. `pv_done` 到来时，同一拍向 Buffer 发出对应 Bank/Group 的 `release_valid`。
5. 子模块或内部协议出错后锁死新命令，必须复位后才能重新运行。

这只改变控制与 Bank 所有权，不改变 RoPE、QK、Mask、Softmax、Repack 或 PV 的数值计算顺序。

## 2. 修正版目录

将本目录中的内容合并到：

```text
<仓库根目录>/A_attention_integration_final_v5/
```

合并完成后应形成：

```text
A_attention_integration_final_v5/
├─ rtl/
│  ├─ adapter/
│  │  └─ pv_tile2_to_tile4_buffer_adapter.sv       # 主仓库原文件
│  ├─ optimization_v24/
│  │  ├─ gqa_overlap_scheduler.sv                  # 修正版
│  │  ├─ gqa_pingpong_buffer.sv                    # 修正版
│  │  └─ attention_overlap_perf_counters.sv
│  └─ top/
│     ├─ attention_system_with_rope_pv_top.sv      # 主仓库串行基线
│     └─ attention_system_with_rope_pv_overlap_top.sv
├─ tb/
│  ├─ optimization_v24/
│  │  ├─ tb_gqa_overlap_scheduler.sv
│  │  ├─ tb_gqa_pingpong_buffer.sv
│  │  └─ tb_attention_overlap_perf_counters.sv
│  └─ tb_attention_system_with_rope_pv_small.sv    # 主仓库现有完整链路 TB
└─ scripts/
   ├─ add_overlap_v24_to_open_project.tcl
   ├─ run_vivado_overlap_unit_regression.tcl
   └─ run_vivado_gqa_overlap_regression.tcl
```

不要把 `corrected_overlap_v24` 整个目录平行放在仓库根目录后就直接运行 Tcl。要复制的是它里面的 `rtl`、`tb`、`scripts` 三个目录，并让它们与 `A_attention_integration_final_v5` 中已有的同名目录合并。

## 3. 合入前必须做的备份

在仓库根目录执行：

```powershell
git status
git switch -c optimization/overlap-v24-integration
git add -A
git commit -m "checkpoint: verified serial attention baseline"
```

如果 `git status` 显示还有不应提交的大文件、Vivado 临时目录或仿真输出，先处理 `.gitignore`，不要盲目执行 `git add -A`。

建议额外保留以下已经通过上板的基线文件：

- 原串行 RTL 的 Git commit ID；
- 原 Bitstream、XSA、ELF；
- 原 utilization、timing、power 报告；
- 原黄金模型 PASS 日志；
- 板上运行结果。

## 4. 原包与修正版如何处理

如果你已经把队友原版文件加入 Vivado：

1. 关闭正在运行的仿真。
2. 在文件系统中先备份原版五个 RTL 文件。
3. 用本修正版覆盖相同相对路径下的文件。
4. Vivado 中不要同时保留两个同名模块的不同副本。
5. 在 **Sources** 窗口中检查每个模块只出现一次。
6. 执行 **Refresh Changed Modules**，然后执行 **Update Compile Order**。

必须唯一的模块名：

- `gqa_overlap_scheduler`
- `gqa_pingpong_buffer`
- `attention_overlap_perf_counters`
- `attention_system_with_rope_pv_overlap_top`

若 Vivado 报 `module ... already declared`，说明旧副本仍在工程中。删除的是工程引用，不要误删主仓库中要保留的修正版文件。

## 5. Vivado 三类源文件应该怎么放

### 5.1 Design Sources

新增的 Design Sources 只有：

- `rtl/optimization_v24/gqa_overlap_scheduler.sv`
- `rtl/optimization_v24/gqa_pingpong_buffer.sv`
- `rtl/optimization_v24/attention_overlap_perf_counters.sv`
- `rtl/top/attention_system_with_rope_pv_overlap_top.sv`

以下是主工程中本来就应存在的依赖，继续保留在 Design Sources：

- `rtl/adapter/pv_tile2_to_tile4_buffer_adapter.sv`
- `attention_with_pv_config_guard.sv`
- RoPE 的全部 RTL；
- QK、Mask、Softmax、B+C 的全部 RTL；
- `bf16_v_cache.sv`；
- real-PV 的全部 RTL；
- 板级 AXI/DMA/控制寄存器模块；
- KV260 的板级 Wrapper 或 Block Design Wrapper。

不要把任何 `tb_*.sv` 放进 Design Sources。

### 5.2 Simulation Sources

新增：

- `tb/optimization_v24/tb_gqa_overlap_scheduler.sv`
- `tb/optimization_v24/tb_gqa_pingpong_buffer.sv`
- `tb/optimization_v24/tb_attention_overlap_perf_counters.sv`

完整链路回归继续使用主仓库中已经验证过的：

- `tb/tb_attention_system_with_rope_pv_small.sv`

仿真 Floating Point 行为模型只放 Simulation Sources，不能参与板级综合。

### 5.3 Memory Initialization Files

完整小规模链路仿真需要：

- `FPT_BC_QK_Softmax_PV_Delivery_v5/rtl/softmax/exp_lut_q15.mem`
- `QK_after_RoPE/tb/data/rope_small_sin.hex`
- `QK_after_RoPE/tb/data/rope_small_cos.hex`

本交付的回归 Tcl 会把它们复制到各个 XSim 运行目录，不需要手工改扩展名。

板级综合使用的 ROM 文件必须与板级参数一致，不能误用只包含小规模测试数据的 `rope_small_*.hex`。

### 5.4 Constraints

三个单元 TB 和小规模行为仿真不需要 XDC。

资源/时序或板级实现时继续使用已经上板通过的 KV260 约束，包括：

- 顶层输入时钟约束；
- 时钟生成/派生时钟约束；
- 复位与 I/O 约束；
- AXI、DMA 或板级接口约束；
- 必要的 CDC 约束。

不要为了消除时序错误随意添加 false path。每条 false path 都必须能解释为什么该路径在硬件上不需要采样。

## 6. 第一步：先跑三个单元测试

先不要打开 GUI 一个个添加 TB。打开 Vivado，在 **Tcl Console** 中执行：

```tcl
cd D:/你的仓库路径/A_attention_integration_final_v5
source scripts/run_vivado_overlap_unit_regression.tcl
```

必须看到：

```text
[PASS] corrected GQA ping-pong Buffer
[PASS] corrected GQA overlap scheduler
[PASS] Attention overlap performance counters
[PASS] CORRECTED GQA OVERLAP UNIT REGRESSION
```

任何一个出现 `$fatal`、`ERROR`、`protocol_error`、计数非零，都不要继续完整链路。

单元回归检查：

- 两个 Bank 的填充与读取映射；
- Bank 0 读取与 Bank 1 填充的真实 overlap；
- B+C/fill 原子启动；
- PV/drain 原子启动；
- 8 个 Group 严格有序；
- Bank 释放；
- duplicate/missing 计数器故障注入。

## 7. 第二步：跑串行版与优化版完整链路逐位比较

运行：

```tcl
cd D:/你的仓库路径/A_attention_integration_final_v5
source scripts/run_vivado_gqa_overlap_regression.tcl
```

该脚本会依次执行：

1. 三个单元 TB；
2. 默认参数静态展开；
3. 原串行完整小规模 Attention；
4. 优化版完整小规模 Attention；
5. 两个 Context 输出文件逐行、逐位比较；
6. 检查重复、缺失、协议错误和 overlap 计数。

最终必须出现：

```text
[PASS] COMPLETE GQA OVERLAP REGRESSION
Bit-exact Context outputs = 512
Bit-exact mismatches      = 0
Duplicate outputs         = 0
Missing outputs           = 0
Error bitmap              = 0
```

同时要求：

- `Overlap cycles > 0`
- `Overlap efficiency > 0%`
- `invalid_fill_count = 0`
- `invalid_drain_count = 0`
- `bank_conflict_count = 0`

如果 Tcl 报以下文件缺失：

```text
rtl/top/attention_system_with_rope_pv_top.sv
tb/tb_attention_system_with_rope_pv_small.sv
```

说明你当前电脑上的主仓库不是此前跑通黄金验证的完整版本。不要临时编造 TB；应从已经跑通过的 commit 或队友电脑取回这两个精确文件。

回归结果默认写到 Git 工作树之外的：

```text
gqa_overlap_regression/
```

重点保留：

- `validation_summary.md`
- `overlap_stats.csv`
- `baseline_context.txt`
- `overlap_context.txt`
- 全部 xvlog/xelab/xsim 日志

## 8. 第三步：加入现有 Vivado 工程

打开你们已经能生成 KV260 Bitstream 的工程，然后执行：

```tcl
cd D:/你的仓库路径/A_attention_integration_final_v5
source scripts/add_overlap_v24_to_open_project.tcl
```

脚本只添加源文件，不擅自修改板级 Design Top。

不同任务对应不同 Top：

| 任务 | Top |
| --- | --- |
| Scheduler 单元仿真 | `tb_gqa_overlap_scheduler` |
| Buffer 单元仿真 | `tb_gqa_pingpong_buffer` |
| Counter 单元仿真 | `tb_attention_overlap_perf_counters` |
| 完整小规模仿真 | `tb_attention_system_with_rope_pv_small` |
| 核心 OOC 资源/时序 | `attention_system_with_rope_pv_overlap_top` |
| KV260 Bitstream | 已上板工程的板级 Wrapper |

板级 Wrapper 必须在其内部实例化优化核心。仅把 `attention_system_with_rope_pv_overlap_top` 加入 Design Sources，但板级 Wrapper 仍实例化旧串行核心，不会得到任何优化。

## 9. 第四步：综合与实现

先做优化核心 OOC 综合，确认 RTL 能落到器件：

```tcl
set_property top attention_system_with_rope_pv_overlap_top \
    [get_filesets sources_1]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
open_run synth_1
report_utilization -file overlap_post_synth_utilization.rpt
report_timing_summary -file overlap_post_synth_timing.rpt
report_ram_utilization -file overlap_post_synth_ram.rpt
```

然后恢复板级 Wrapper 为 Top，重新综合、实现和生成 Bitstream：

```tcl
set_property top <你们已经上板成功的KV260板级Wrapper名> \
    [get_filesets sources_1]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_utilization -file overlap_post_route_utilization.rpt
report_timing_summary -file overlap_post_route_timing.rpt
report_power -file overlap_post_route_power.rpt
report_drc -file overlap_post_route_drc.rpt
```

实现结果最低门槛：

- `WNS >= 0`
- `TNS = 0`
- hold violation 为 0
- DRC 中没有 Error
- 没有 black box
- LUT、FF、BRAM、DSP 均未超过器件容量
- 生成 Bitstream 成功

## 10. 必须关注的资源风险

当前 `pv_tile2_to_tile4_buffer_adapter` 使用数组异步读。即使数组名称叫 Bank，综合器也不一定将它推断成 BRAM，可能使用 LUTRAM 或大量 LUT。双 Bank 会放大这个问题。

综合后必须查看：

```tcl
report_utilization -hierarchical
report_ram_utilization
```

重点确认：

1. `u_pingpong/u_bank0` 和 `u_pingpong/u_bank1` 的存储落在 BRAM/URAM 还是 LUTRAM；
2. LUT 是否从基线约 58% 上升到危险区；
3. BRAM 是否接近或超过 KV260 容量；
4. 新增 Scheduler 本身应只占很少逻辑，主要增量应来自第二个 Group Bank。

建议判据：

- LUT 或 BRAM `< 75%`：较安全；
- `75%～85%`：能继续，但布线和提频风险上升；
- `> 85%`：优先做存储重构，不建议立即上板提交；
- 任何资源 `> 100%`：必须重构，不能靠修改约束解决。

如果两个 Bank 未映射到 BRAM，应把 Repack 存储改成同步读 BRAM 接口，并在 PV 请求侧增加一拍 read-valid。这个改动会影响握手和延迟，必须重新跑本文所有回归，不能只加 `ram_style` 属性后直接认定成功。

## 11. 第五步：性能验收

仅有 `overlap_cycles > 0` 证明并行真实发生，但还不足以证明端到端加速。

必须同时记录串行版和优化版：

- 总周期数；
- 时钟频率；
- 单次 Attention 延迟；
- 吞吐；
- LUT、FF、BRAM、DSP；
- 功耗；
- 板上 10 次运行结果。

计算：

```text
latency_ms = total_cycles / f_clk_hz × 1000
speedup = serial_total_cycles / overlap_total_cycles
overlap_efficiency =
    overlap_cycles / min(bc_cycles, pv_cycles)
```

论文中不能只报告 87% 的 overlap efficiency。还应报告端到端 speedup，因为 B+C 比 PV 慢时，即使 PV 的绝大多数周期被覆盖，总延迟改善也可能有限。

## 12. 当前最稳妥的执行顺序

按以下顺序做，不要跳步：

1. 建优化分支并冻结原上板基线。
2. 合并本修正版目录。
3. 跑三个单元回归。
4. 跑串行/优化完整链路逐位比较。
5. 保存 PASS 日志和输出 SHA-256。
6. 做优化核心 OOC 综合。
7. 检查两个 Bank 的真实存储映射和资源余量。
8. 把优化核心接入 KV260 板级 Wrapper。
9. 跑完整综合、实现、DRC、时序和功耗。
10. 生成新 Bitstream。
11. 板上连续运行至少 10 次。
12. 同一输入下比较优化前后输出与周期，形成论文表格。

在第 4 步没有通过前，不做上板；在第 7 步资源未确认前，不承诺该结构能装入 KV260；在第 9 步 WNS/DRC 未通过前，不把 Bitstream 当成最终交付。

## 13. 这次队友还应补交的证据

虽然本修正版补了 TB，但仍建议向队友索取原始交付证据：

- 报告中实际运行过的原始三个单元 TB；
- 实际运行过的完整链路 TB；
- 完整 Vivado/XSim 日志；
- `baseline_context.txt` 与 `overlap_context.txt`；
- `overlap_stats.csv`；
- 对应 Git commit ID；
- 全部文件 SHA-256；
- Vivado 版本和执行命令。

报告中的结论可以作为参考，但比赛提交应以你们自己在最终 commit 上重新跑出的结果为准。

