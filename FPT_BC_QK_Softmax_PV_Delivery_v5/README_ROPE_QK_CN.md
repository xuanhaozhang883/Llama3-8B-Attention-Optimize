# RoPE 后 QK 相乘模块——交付与使用说明

## 1. 本次完成内容

本次在现有 QK / Mask / Softmax / PV 流水线前加入了可综合的 RoPE 处理与缓存，形成以下数据通路：

```text
原始 BF16 Q/K（split-half 成对读取）
  -> RoPE 旋转
  -> Group 内 Q/K BRAM 缓存
  -> 原有 QK 脉动阵列相乘与累加
  -> Causal Mask / Softmax / P Buffer / PV Loader
```

RoPE 对每一对输入执行：

```text
y0 = x0*cos - x1*sin
y1 = x0*sin + x1*cos
```

其中 `x0=vector[pair]`，`x1=vector[pair+HEAD_DIM/2]`。默认配置为
`SEQ_LEN=128`、`HEAD_DIM=128`、每组 4 个 Q head、共 8 个 GQA Group。

主要新增文件：

```text
rtl/rope/rope_pair_pipeline.sv
rtl/rope/rope_group_prepare.sv
rtl/rope/rope_qk_group_cache.sv
rtl/integration/rope_group_bridge.sv
rtl/integration/rope_qk_softmax_pv_pipeline_top.sv
rtl/integration/rope_qk_softmax_pv_system_top.sv
tb/tb_rope_qk_pipeline_small.sv
tb/data/rope_small_sin.hex
tb/data/rope_small_cos.hex
```

推荐的单 Group 综合顶层是：

```text
rope_qk_softmax_pv_pipeline_top
```

若需要一次 `start` 自动运行 Group 0～7，可使用：

```text
rope_qk_softmax_pv_system_top
```

## 2. 资源优化方式

为减少 LUT/CLB 与 DSP 占用，RoPE 没有为每个 Q/K head 并行复制计算单元：

- 全部 4 个 Q head 和 1 个 K head共用一个 RoPE pair 数据通路。
- RoPE pair 内部只复用一个 FP32 乘法 IP 和一个 FP32 加法 IP，依次完成 4 次乘法和 2 次加减法。
- 每次乘法结果先舍入到 BF16，再进入加法，保持分级 BF16 边界。
- 旋转后的 Q/K 按 `token % QK_TILE` 分 bank 存储，综合为 Block RAM。
- 缓存采用同步读，向 QK 阵列送数时插入一个读取气泡；当前版本优先保证资源、BRAM 推断和正确性。

Vivado 2025.2、`xc7a100tcsg324-1`、100 MHz OOC 综合结果：

| 范围 | LUT | FF | DSP | RAMB36 | RAMB18 |
|---|---:|---:|---:|---:|---:|
| 完整单 Group 顶层 | 11,500 | 17,314 | 72 | 40 | 3 |
| 新增 RoPE bridge | 2,896 | 1,100 | 4 | 40 | 0 |

综合审计结果：

- WNS：`+0.211 ns`，满足 100 MHz 综合时序约束。
- latch：0。
- black box：0。
- RoPE Q/K cache：40 个 RAMB36，未展开成大规模寄存器阵列。
- 综合阶段无 error、无 critical warning。

注意：这是模块级 OOC 综合结果。当前工程没有板级管脚、时钟源和完整实现约束，因此它用于 RTL/IP/资源/综合时序审查，不是可以直接生成上板 bitstream 的完整板级工程。

## 3. 推荐：全部使用 Vivado GUI 检验

本交付已经准备好两个 `.xpr`，日常检验不需要输入命令：

| 检验目的 | 直接双击的工程 |
|---|---|
| 检查 RoPE 后向量和 QK 数值 | `vivado_rope_qk_small_sim/fpt_rope_qk_small.xpr` |
| 检查完整顶层、IP、资源和 100 MHz 时序 | `vivado_synth_rope_qk_pipeline/fpt_bc_ooc_synth.xpr` |

### 3.1 GUI 功能仿真

双击：

```text
D:\Vitis\FPT\Llama3-8B-Attention-Optimize\FPT_BC_QK_Softmax_PV_Delivery_v5\vivado_rope_qk_small_sim\fpt_rope_qk_small.xpr
```

在 Vivado 2025.2 中依次点击：

```text
Flow Navigator
  -> SIMULATION
  -> Run Simulation
  -> Run Behavioral Simulation
```

工程已将仿真顶层设置成 `tb_rope_qk_pipeline_small`，运行时间设置成
`100 us`。因此点击后会自动运行到 testbench 的 `$finish`，不需要在 Tcl
Console 输入 `run all`。

检验结果的方法：

1. 查看窗口下方的 `Tcl Console`，应出现：

   ```text
   TEST_RESULT: PASS RoPE->QK Group 7 scores=64
   ```

2. `Waveform` 窗口用于看波形。若需要重新开始，点击仿真工具栏的
   `Restart`，再点击 `Run All`。
3. 若要看内部信号，在左侧 `Scopes` 选择 `tb_rope_qk_pipeline_small` 下的
   DUT，在 `Objects` 中选中信号，右键 `Add to Wave Window`，然后重新运行。
4. 重点可观察 `q_vec_valid`、`q_vec_bf16`、`k_vec_bf16`、
   `score_valid`、`score_bf16`、`score_last`。

该仿真检查：

- Q `(1,2)` 经 90° RoPE 后为 `(-2,1)`。
- K `(3,4)` 经 90° RoPE 后为 `(-4,3)`。
- Group 7 正确映射到全局 Q28～Q31 和 K7。
- 全部 64 个 QK 结果为十进制 22，即 BF16 `0x41B0`。

### 3.2 GUI 综合、资源和时序检查

双击：

```text
D:\Vitis\FPT\Llama3-8B-Attention-Optimize\FPT_BC_QK_Softmax_PV_Delivery_v5\vivado_synth_rope_qk_pipeline\fpt_bc_ooc_synth.xpr
```

该工程已经完成综合。打开后：

1. 在 `Flow Navigator -> SYNTHESIS` 点击 `Open Synthesized Design`。
2. 检查资源：点击 `Reports -> Report Utilization`，确认总计约为
   11,500 LUT、17,314 FF、72 DSP、40 RAMB36、3 RAMB18。
3. 检查时序：点击 `Reports -> Timing -> Report Timing Summary`，时钟周期选择
   10 ns；已生成结果的 `Design Timing Summary` 中应看到 `WNS = +0.211 ns`。
4. 检查 RoPE 资源：在左侧 `Netlist` 展开顶层的 `u_rope_bridge`；其综合结果为
   2,896 LUT、1,100 FF、4 DSP、40 RAMB36。
5. 查看原理图：在 `Netlist` 中选择 `u_rope_bridge`、`u_prepare` 或
   `u_pair_pipeline`，右键选择 `Schematic`。
6. 查看 IP：回到 `Project Manager`，在 `Sources -> IP Sources` 中可以看到
   QK 和 RoPE 使用的 Floating-Point IP。

如果你修改了 RTL，需要在左侧 `Flow Navigator -> SYNTHESIS` 点击
`Run Synthesis`。完成后再次进入 `Open Synthesized Design` 查看新结果。

### 3.3 GUI 中查看源码

打开后在 `Sources -> Design Sources` 中查看顶层
`rope_qk_softmax_pv_pipeline_top`。主要层级为：

```text
rope_qk_softmax_pv_pipeline_top
  -> u_rope_bridge
       -> u_prepare
            -> u_pair_pipeline
       -> u_cache
  -> u_pipeline
       -> 原有 QK / Mask / Softmax / P / PV 数据通路
```

## 4. 可选：重新生成工程

一般 GUI 检验不需要执行本节。只有工程目录被删除、IP 需要重新生成，或希望从
RTL 完整重建 XPR 时，才需要运行脚本。

### 4.1 在 Vivado GUI 内重新生成仿真工程

启动 Vivado 空白界面，点击：

```text
Tools -> Run Tcl Script...
```

选择：

```text
FPT_BC_QK_Softmax_PV_Delivery_v5/run_vivado_rope_qk_small.tcl
```

脚本会重新创建仿真 XPR、启动 XSim 并自动检查 PASS。完成后重新双击
`vivado_rope_qk_small_sim/fpt_rope_qk_small.xpr` 即可。

### 4.2 在 Vivado GUI 内重新生成综合工程

启动 Vivado 空白界面，点击 `Tools -> Run Tcl Script...`，选择：

```text
FPT_BC_QK_Softmax_PV_Delivery_v5/run_synthesis_rope_qk_pipeline.tcl
```

脚本会重新创建 XPR、生成 Floating-Point IP、运行 100 MHz OOC 综合，并输出
全部审计报告。运行期间可在 `Tcl Console` 和右上角任务状态中查看进度。

脚本使用 `create_project -force`，会重新建立生成目录。若你在 XPR 中做了手工
修改，先把修改同步到 RTL/Tcl 源文件或备份工程，再执行脚本。

## 5. 可选：命令行自动回归

只有需要无人值守自动测试时才使用本节；日常结果检验直接使用第 3 节 GUI。

先进入交付目录：

```powershell
Set-Location 'D:\Vitis\FPT\Llama3-8B-Attention-Optimize\FPT_BC_QK_Softmax_PV_Delivery_v5'
```

运行 Vivado XSim：

```powershell
& 'D:\Vitis\2025.2\Vivado\bin\vivado.bat' -mode batch -source run_vivado_rope_qk_small.tcl -nojournal -nolog
```

预期终端输出：

```text
TEST_RESULT: PASS RoPE->QK Group 7 scores=64
```

该测试使用 `SEQ_LEN=4`、`HEAD_DIM=4` 和精确 90° 旋转，检查：

- Q `(1,2)` 旋转为 `(-2,1)`。
- K `(3,4)` 旋转为 `(-4,3)`。
- Group 7 映射到全局 Q28～Q31 和 K7。
- 64 个 QK 结果全部为十进制 22，即 BF16 `0x41B0`。

仿真日志位于：

```text
vivado_rope_qk_small_sim/fpt_rope_qk_small.sim/sim_1/behav/xsim/simulate.log
```

### 5.1 命令行重新综合

在同一目录执行：

```powershell
& 'D:\Vitis\2025.2\Vivado\bin\vivado.bat' -mode batch -source run_synthesis_rope_qk_pipeline.tcl
```

脚本会执行以下操作：

1. 重新创建 `vivado_synth_rope_qk_pipeline/fpt_bc_ooc_synth.xpr`。
2. 创建并接入现有 FP32 Floating-Point IP。
3. 以 `rope_qk_softmax_pv_pipeline_top` 为顶层运行 100 MHz OOC 综合。
4. 检查 latch、black box、多驱动、BRAM 推断和最差建立时序。
5. 生成 DCP、资源、时序、关键路径、RAM 和方法学报告。

最简审计摘要：

```text
reports/rope_qk_pipeline_artix7/SYNTHESIS_AUDIT_SUMMARY.txt
```

完整报告目录：

```text
reports/rope_qk_pipeline_artix7/
```

## 6. 外部 Q/K 存储器如何连接

顶层通过 ready/valid 接口请求原始 Q/K pair：

```text
请求：raw_req_valid / raw_req_ready
      raw_req_is_k
      raw_req_head
      raw_req_token
      raw_req_pair

响应：raw_rsp_valid / raw_rsp_ready
      raw_rsp_x0
      raw_rsp_x1
```

一次请求只允许一个 outstanding transaction。请求握手后，外部存储器应返回相同请求对应的：

```text
raw_rsp_x0 = vector[raw_req_pair]
raw_rsp_x1 = vector[raw_req_pair + HEAD_DIM/2]
```

`raw_req_is_k=0` 表示 Q，`raw_req_is_k=1` 表示 K。对于 Group `g`：

```text
global_q_head = g*4 + local_q_head
global_k_head = g
```

启动单 Group 时，仅在 `group_start_ready=1` 时送一个 `group_start` 脉冲，并同时给出 `group_id`。RoPE 装载完成后会自动启动原有 QK/Softmax/PV 流水线；最终 `done=1` 表示该 Group 的最后一个 PV 输入向量已经完成握手。

如果只需要观察 RoPE 后的 QK 分数，而不需要后续 Softmax/PV，可参考
`tb/tb_rope_qk_pipeline_small.sv` 的连接方式：将 `rope_group_bridge` 的
`q_vec_bf16/k_vec_bf16/qk_vec_valid` 直接连接到 `qk_systolic_gqa_top`。

## 7. ROM 与数据格式

- Q、K、sin、cos、缓存和 QK 输入均采用 BF16，每个标量 16 bit。
- 正式综合默认读取仓库 `RoPE/data/sin_bf16.hex` 和 `RoPE/data/cos_bf16.hex`。
- 地址为 `token*(HEAD_DIM/2)+pair`，深度默认 `SEQ_LEN*(HEAD_DIM/2)`。
- QK 内部继续使用现有 BF16→FP32、FP32 MAC 和 FP32→BF16 缩放路径。

更细的接口与设计说明见 `doc/ROPE_QK_INTEGRATION.md`。
