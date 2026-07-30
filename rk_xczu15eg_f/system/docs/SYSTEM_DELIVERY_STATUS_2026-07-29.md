# RK-XCZU15EG-F 系统交付状态（2026-07-29）

## 1. 结论

目标器件为 `xczu15eg-ffvb1156-2-i`，工具版本为 Vivado/Vitis 2025.2。
当前已完成三个可在 GUI 中直接打开的 Vivado 工程、对应 bitstream/XSA，
以及 PS DDR、DMA 回环和单 GQA Attention 的 A53 裸机软件基础。

本轮按要求没有运行行为仿真。以下 `SOFTWARE_PASS` 只表示工具链构建、
布线、时序、DRC、bitstream/XSA 或 ELF 生成成功；未连接实板执行的项目
仍统一标记为 `HARDWARE_PENDING`。

## 2. GUI 工程与产物

### 2.1 PS DDR + AXI DMA 回环

- Vivado XPR：`system/vx/ps_dma_loopback/rk_ps_dma_loopback.xpr`
- 状态：bitstream/XSA `SOFTWARE_PASS`，实板 `HARDWARE_PENDING`
- 实现时序：WNS `+6.027 ns`，时序约束满足
- bitstream SHA-256：
  `2B0B9DE25953686D5996CF7DCE3C5B8FDC817D3FCDFED8D4B9994A04360DFEAC`
- XSA SHA-256：
  `D5953157AE3F866BAE449EA238D0023A99850B68BAD1BD825CB09E3B228A3AAB`
- 已构建 Vitis GUI 工作区：
  `D:\Vitis\vitis_ws\rope-qk-integration\dma_loopback`
- `ps_ddr_test.elf` SHA-256：
  `DC80C9A59ADDD8729ED4F58E05C21BB03B48D0FFD3B3A3BA3F15D715A3AC698A`
- `dma_loopback.elf` SHA-256：
  `D8D48D8C1AA8D2B76235C4B863A83A4E46B1D06649D71301D496890C51754777`

### 2.2 厂商 PL DDR 自检

- Vivado XPR：`system/vx/pl_ddr/rk_pl_ddr.xpr`
- 状态：bitstream/XSA `SOFTWARE_PASS`，实板 `HARDWARE_PENDING`
- 实现时序：WNS `+0.493 ns`、WHS `+0.011 ns`
- bitstream SHA-256：
  `721F814ECF7376628C3652F780E183FF8BD2CCBB9F9902BC08294A119D2762B3`
- XSA SHA-256：
  `5F024079C5302550A06E8E29364555FF834BE29ABA401833163922B20CB4AF87`
- 上板必须观察 `init_calib_complete == 1` 且 `error == 0`
- 板上 `LY-062E` 与厂商 XCI 中 `MT40A512M16HA-083E` 的等价性仍需实板确认

### 2.3 PS DDR + DMA + 单 GQA Attention

- Vivado XPR：`system/vx/ps_attention/rk_ps_attention_single_gqa.xpr`
- 状态：bitstream/XSA/A53 ELF `SOFTWARE_PASS`，实板 `HARDWARE_PENDING`
- PL 时钟：`96.968727 MHz`
- AXI DMA MM/Stream 宽度：`128 bit`
- Attention AXI-Lite 基地址：`0xA0000000`
- DMA AXI-Lite 基地址：`0xA0010000`
- 签核时序：WNS `+1.225 ns`、TNS `0`，全部用户时序约束满足
- 路由：failed nets `0`、unrouted nets `0`、partially routed nets `0`、
  node overlaps `0`
- Methodology：`0` 项
- DRC：`0 Error`；44 条 Warning/Advisory 为 DSP 流水建议、
  BRAM no-change collision 提示和无可路由负载提示
- 顶层资源：`56,169 LUT`、`41,896 FF`、`93 RAMB36`、`9 RAMB18`、
  `136 DSP`
- bitstream SHA-256：
  `B8891CEC556BDBBD8D3C502D66A7F138D9EE0FC696832CD6F032FF1B98A679EB`
- XSA SHA-256：
  `23D92B9CD2467C49132DBCEE6A80A117310BB5F6E8D59E5F02D41C33923EF21E`

A53 Vitis GUI 工作区使用超短路径：

```text
D:\Vitis\ws\rka
```

- `ps_ddr_test.elf` SHA-256：
  `1970E6D9D80E76ADEDB749E643F42C2F3D73AE08D9FDCB3DC973E81BFC0EEAEF`
- `attention_single_gqa.elf` SHA-256：
  `1A75EBC2620F2DDAC5D03585F7EAFAEF60D1185230A2A21754537C8E46A58DCE`

Attention 工作区不能放在较长的
`D:\Vitis\vitis_ws\rope-qk-integration\attention_single_gqa` 下。Vitis
生成 A53 BSP 时会超过 Windows `MAX_PATH`，导致
`translation_table.S.obj.d: No such file or directory`。脚本默认路径现已
改为 `D:\Vitis\ws\rka`。

## 3. Q/K/V 与资源实现

单 GQA 固定输入帧为：

```text
Q[4][128][128], K[1][128][128], V[1][128][128], BF16
```

Q/K/V 通过三个显式 `xpm_memory_sdpram` 缓冲。独立结构检查结果为：

- LUTRAM：`0`
- RAMB36E2：`42`
- RAMB18E2：`3`

其中 Q 为 `8K x 128 bit`，K/V 各为 `2K x 128 bit`。完整 Attention
内核仍含已有的 `RAM64M8` 等分布式 RAM，这是后续资源优化项，不是 Q/K/V
XPM 缓冲回退成 LUTRAM。

软件已提供弱符号数据接口：

```text
system/software/common/attention_data_provider.h
system/software/common/attention_data_provider.c
```

默认实现只提供占位零数据，不能形成比赛正确性结论。团队需要用同一模型层、
同一 token 范围导出的 BF16 Q/K/V 和 Context Golden 覆盖弱符号实现。

## 4. GUI 操作

### 4.1 Vivado

在 Vivado 2025.2 中选择 **File → Open Project**，打开第 2 节对应的
`.xpr`。依次检查：

1. **IP Integrator → Open Block Design**；
2. **Validate Design**；
3. **Design Runs** 中的 `synth_1` 和 `impl_1`；
4. **Open Implemented Design → Reports → Timing Summary / Utilization**；
5. 需要重新生成时依次执行 **Run Synthesis → Run Implementation →
   Generate Bitstream**；
6. 导出 XSA 时使用 **File → Export → Export Hardware** 并勾选
   **Include bitstream**。

Attention RTL 修改后先重新运行工程生成器，避免复用旧 OOC checkpoint：

```powershell
& 'D:\Vitis\2025.2\Vivado\bin\vivado.bat' `
  -mode batch -nojournal -nolog -notrace `
  -source .\rk_xczu15eg_f\system\bd\create_ps_attention_project.tcl
```

### 4.2 Vitis

打开单 GQA 工作区：

```powershell
& 'D:\Vitis\2025.2\Vitis\bin\vitis.bat' -w 'D:\Vitis\ws\rka'
```

在 Vitis GUI 中先运行 `ps_ddr_test`，再运行 `attention_single_gqa`。
使用 **Run → Run Configurations → Single Application Debug**，通过 JTAG
下载平台 bitstream 和对应 ELF。

## 5. 实板验收顺序

1. 检查供电、拨码、JTAG、UART 和启动模式；
2. 运行 `ps_ddr_test`，cache-on/cache-off pattern 均必须通过；
3. 运行 DMA 回环的 1、5、16、63、64、4096、65536、1 MiB 八种长度；
4. 运行 PL DDR 自检，确认校准完成且无错误；
5. 单 GQA 先用占位数据验证控制/数据通路不超时；
6. 接入真实 Q/K/V 和 Golden，串口必须显示 `qkv_mode=real` 且
   `golden_mismatches=0`；
7. 同时记录 `kernel_cycles`、DMA ticks 和应用 ticks，形成端到端延迟；
8. 单 GQA 正确且稳定后，再扩展到 8 GQA 并做资源/带宽调度。

## 6. 仍未完成的最终项目目标

- 三个工程的 RK-XCZU15EG-F 实板日志和截图；
- PL DDR 器件等价性及长时间压力测试；
- 真实模型 Q/K/V/Golden 数据提供器；
- 8 个 GQA 的调度、KV Cache 分块和 DMA 双缓冲；
- 首 token、单 token、连续 token 的端到端延迟与吞吐；
- 功耗、带宽、资源、频率和消融实验；
- 比赛可复现 release 包。

因此当前工程基础建设已完成，但不能宣称整个比赛项目已经完成或硬件已经跑通。

## 7. Git 交付边界

提交 RTL、Tcl、C、Python、PowerShell 和文档。`system/vx`、
`system/generated`、Vitis 工作区、厂商缓存和临时日志均为可再生或许可边界
不明确的内容，不整目录提交。BIT/XSA/ELF 如需发布，使用 GitHub Release
或 Git LFS，并同时记录 SHA-256、器件、工具版本和对应 commit。
