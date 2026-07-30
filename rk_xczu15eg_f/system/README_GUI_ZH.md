# RK-XCZU15EG-F：Vivado/Vitis GUI 使用说明

本文对应器件 `xczu15eg-ffvb1156-2-i`，目标板为
RK-XCZU15EG-F V1.0。当前轮次没有运行行为仿真；完成的是 RTL、IP、
Block Design、综合/实现、bitstream/XSA 和 A53 裸机软件基础。

## 已完成的工程

| 工程 | Vivado GUI 启动文件 | 当前状态 |
|---|---|---|
| PS DDR + DMA 回环 | `system/vx/ps_dma_loopback/rk_ps_dma_loopback.xpr` | bitstream/XSA `SOFTWARE_PASS` |
| PL DDR 厂商自检 | `system/vx/pl_ddr/rk_pl_ddr.xpr` | bitstream/XSA `SOFTWARE_PASS` |
| PS DDR + DMA + 单 GQA Attention | `system/vx/ps_attention/rk_ps_attention_single_gqa.xpr` | bitstream/XSA/A53 ELF `SOFTWARE_PASS` |

`SOFTWARE_PASS` 只代表工具链构建成功。未在实板观察到串口输出、DDR 校准和
DMA/Attention 结果前，统一保持 `HARDWARE_PENDING`。

## 系统结构

单 GQA 工程的数据路径为：

```text
PS DDR
  → AXI DMA MM2S（128 bit）
  → Q/K/V XPM BRAM
  → RoPE → QK → Scale/Mask → Softmax → PV
  → AXI DMA S2MM（128 bit）
  → PS DDR
```

输入固定为 BF16：

- Q：`[4][128][128]`
- K：`[1][128][128]`
- V：`[1][128][128]`
- 输入总计：196,608 bytes
- Context 输出：`[4][128][128]`，131,072 bytes

完整帧格式和 AXI-Lite 寄存器见
`system/docs/DATA_PROTOCOL.md`。

## Vivado GUI 操作

直接双击目标 `.xpr`，或在 Vivado 2025.2 中选择
**File → Open Project**。

打开工程后建议按顺序检查：

1. **IP Integrator → Open Block Design**。
2. 执行 **Validate Design**。
3. 在 **Sources** 中确认顶层 wrapper。
4. 查看 **Design Runs**：
   - `synth_1`
   - `impl_1`
5. 需要自己重跑时依次点击：
   - **Run Synthesis**
   - **Run Implementation**
   - **Generate Bitstream**
6. 导出 XSA：
   **File → Export → Export Hardware**，勾选 **Include bitstream**。

脚本化非仿真构建入口：

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_attention `
  -BuildMode bitstream `
  -Jobs 4
```

修改 Attention RTL 后，应先重新运行：

```powershell
& 'D:\Vitis\2025.2\Vivado\bin\vivado.bat' `
  -mode batch -nojournal -nolog -notrace `
  -source .\rk_xczu15eg_f\system\bd\create_ps_attention_project.tcl
```

该生成脚本会重建自己管理的 `system/vx/ps_attention` 目录，防止旧的 OOC
checkpoint 被复用。源码和 Stage1 工程不会被删除。

## Vitis GUI：DMA 回环

已生成工作区：

```text
D:\Vitis\vitis_ws\rope-qk-integration\dma_loopback
```

GUI 启动：

```powershell
& 'D:\Vitis\2025.2\Vitis\bin\vitis.bat' `
  -w 'D:\Vitis\vitis_ws\rope-qk-integration\dma_loopback'
```

工作区包含：

- `rk_dma_platform`
- `ps_ddr_test`
- `dma_loopback`

选择应用后使用 **Run → Run Configurations → Single Application Debug**，
通过 JTAG 下载 bitstream 和 ELF。先运行 `ps_ddr_test`，再运行
`dma_loopback`。

DMA 测试必须通过 1、15、16、63、64、4096、65536 和 1 MiB 八种长度。
任何 timeout 或 mismatch 都不能算通过。

工作区可重复生成：

```powershell
.\rk_xczu15eg_f\system\scripts\create_vitis_workspace.ps1 `
  -Profile dma_loopback `
  -Recreate
```

Vitis 工作区使用短路径是为了避开 Windows 260 字符限制；源码仍在仓库内。

## Vitis GUI：单 GQA Attention

Attention XSA 完成后生成工作区：

```powershell
.\rk_xczu15eg_f\system\scripts\create_vitis_workspace.ps1 `
  -Profile attention_single_gqa `
  -Recreate
```

默认位置（为避开 Windows `MAX_PATH`，必须保持短路径）：

```text
D:\Vitis\ws\rka
```

GUI 启动：

```powershell
& 'D:\Vitis\2025.2\Vitis\bin\vitis.bat' -w 'D:\Vitis\ws\rka'
```

应用会记录：

- DMA 端到端 ticks；
- 应用总 ticks；
- 硬件 `kernel_cycles`；
- 输入/输出 beat；
- FIFO stall cycles；
- 错误向量；
- 有真实 Golden 时的 mismatch 数。

默认弱数据提供器只生成全零占位数据，不能用于比赛正确性结论。把同一模型层、
同一 token 范围导出的 BF16 Q/K/V 和 Context Golden 以强符号实现：

```c
int rk_attention_prepare_qkv(...);
int rk_attention_prepare_golden(...);
```

接口定义在：

```text
system/software/common/attention_data_provider.h
```

串口必须显示 `qkv_mode=real`、`golden_mismatches=0`，并且状态/错误向量正常，
才可记录端到端正确性与延迟。

## PL DDR 上板边界

PL DDR 工程已基于厂商 XCI/XDC 完成工具链构建，但板上器件丝印
`LY-062E` 与 XCI 中的 `MT40A512M16HA-083E` 等价性仍需实板确认。

在 Hardware Manager 中必须观察：

```text
init_calib_complete == 1
error == 0
```

没有这两项证据，不要把 PL DDR 接入主 Q/K/V 数据通路。

## 推荐的上板顺序

1. PL 基础自检重复通过。
2. PS DDR cache-on/cache-off pattern 全通过。
3. DMA 回环八种长度全通过。
4. PL DDR 校准和读写压力测试通过。
5. 单 GQA 占位数据完成一次控制/数据通路交易。
6. 换成真实 Q/K/V 与 Golden，确认 mismatch 为 0。
7. 记录 kernel、DMA 和应用三层延迟。
8. 单 GQA 稳定后再扩展到 8 GQA。

## Git 交付边界

建议提交 RTL、Tcl、C/Python/PowerShell 源码和 README。Vivado/Vitis 的
`system/generated`、`system/vx`、工作区和临时日志都是可再生文件，不应整目录
提交。BIT/XSA/ELF 如需发布，应使用 GitHub Release 或 Git LFS，并同时提供
SHA-256、Vivado/Vitis 版本、器件型号和对应 commit。
