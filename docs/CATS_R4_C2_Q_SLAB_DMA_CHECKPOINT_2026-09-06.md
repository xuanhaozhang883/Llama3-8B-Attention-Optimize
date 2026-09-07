# CATS-R4 C2 Q-slab DMA 检查点

状态：`LOCAL CHECKPOINT / NOT READY / DO NOT BOARD TEST`

日期：2026-09-06（Asia/Shanghai）

## Git 身份

- 仓库：`https://github.com/xuanhaozhang883/Llama3-8B-Attention-Optimize.git`
- 本地分支：`codex/cats-r4-local-integration`
- 统一基线：`964da3a42245ddc7fe05a9d86c1be9d21c9bd997`
- Q/K/V IF_V2 ownership 检查点：
  `1a0a91ced7579ae68153b1145949a6ac79c0d898`
- 本次 Q-slab DMA RTL 检查点：
  `765db6d38580a2b9f284e920b48efd95dcbcfabc`
- 用户原有未提交改动继续保存在 `stash@{0}`；本次未删除、应用或改写该 stash。
- 检查点提交后工作区干净；没有 push、merge、移动 tag 或上传产物。

本次 RTL commit 修改：

- `rtl/core/cluster/cats_r4_q_slab_dma_controller.sv`
- `rtl/core/cluster/cats_r4_axi_burst_splitter.sv`
- `tb/tb_cats_r4_q_slab_dma_controller.sv`
- `scripts/cats_r4_q_slab_dma_ooc.tcl`

## 实现闭合

- 每个 Q slab 固定一个 4,096-byte read descriptor，即 512 个 64-bit beat、2 个 256-beat burst。
- DDR 地址为 `q_base + (global_q_head << 15) + (row_window << 12)`。
- descriptor 和 publish token 在 backpressure 下保持稳定。
- completion 同时匹配 12-bit opaque tag 和 16-bit epoch；tag 编码包含 Q source prefix、buffer、global Q head 和 row window。
- 单 cluster 固定顺序闭合 256 slabs；正常路径计数为 256 descriptors、131,072 beats、512 bursts、1,048,576 bytes。
- 错 tag、错 epoch、DMA error 和非 4 KiB 对齐基址阻止完成并进入 halted 状态。
- burst splitter 的 tag 宽度改为参数化，默认仍为 8 bit；旧 splitter 与旧 group-scheduler 回归均通过。

## 验证命令与构建根

所有生成文件均位于 clone 外的新短 ASCII 目录。

Icarus 全负载回归根：

`D:/Vitis/FPT/c2_qdma_final_1a0a91c_20260906`

核心命令：

```text
iverilog -g2012 -Wall -s tb_cats_r4_q_slab_dma_controller \
  cats_r4_axi_burst_splitter.sv cats_r4_q_slab_dma_controller.sv \
  tb_cats_r4_q_slab_dma_controller.sv
vvp qdma.vvp
```

结果：

```text
PASS CATS_R4_IF_V2 Q DMA 256 descriptors/131072 beats/512 bursts
```

Vivado 2025.2 XSim 根：

`D:/Vitis/FPT/c2_qdma_xsim_1a0a91c_20260906_r2`

使用 `xvlog -sv`、`xelab`、`xsim -runall` 运行同一 testbench，结果同样 PASS。

Vivado 2025.2 OOC 根：

`D:/Vitis/FPT/c2_qdma_ooc_1a0a91c_20260906_r6`

核心命令：

```text
vivado -mode batch -notrace \
  -source scripts/cats_r4_q_slab_dma_ooc.tcl \
  -tclargs <clone-root> <new-build-root> 6.666
```

工具/器件/许可证事实：

- Vivado v2025.2 64-bit，SW Build 6299465，IP Build 6300035。
- 目标器件 `xczu15eg-ffvb1156-2-i`。
- 本次实际取得 `Synthesis`/`xczu15eg` 合法许可证；未记录服务器、路径或其他敏感字段。
- OOC run 约从 14:26:34 到 14:28:11。

## OOC 报告

这是受约束的 synthesis-only OOC setup 结果，不是 full-board post-route PPA。

| 项目 | 结果 |
|---|---:|
| core clock | 150.015 MHz / 6.666 ns |
| setup WNS / TNS | +3.420 ns / 0.000 ns |
| setup failing endpoints | 0 |
| unconstrained path table | empty |
| methodology checks | 0 |
| CLB LUT | 162 |
| CLB registers | 870 |
| BRAM / DSP / URAM | 0 / 0 / 0 |

OOC hold 未作为通过证据：未放置的综合 netlist 不具备真实 full-board clock insertion。
Hold、route、DRC 和功耗只能由后续 placed/routed full-board run 给出。

报告 SHA-256：

```text
576C4C249D4940B0312D0C97D32CD1582986684E472703E8AA1D491E7C794D87  q_slab_dma_ooc.dcp
AA8D9AB50A472646FC738CC22140E9D0FF23A732DEBE44B2EE509CF59482A8F9  utilization.rpt
21F0BE09BD58B8379CCD0D91946D9A7F21B3C87D882FA6ABF6178379B8751696  timing_summary.rpt
605EBAA6B6EAC69906EA4A68FE00981B42BEDF594DD89DF21016FB28686F2C3A  methodology.rpt
```

## 未解除的 C2 门禁

- A READY、B READY 与真实 compute-cluster wrapper 仍未在本基线出现。
- 本次 adapter 尚未接 shared HP0 descriptor arbiter；旧
  `cats_r4_dma_group_scheduler.sv` 仍把整组 Q 当成一个 128 KiB descriptor，
  只保留作 v1 原型，不得进入生产 manifest。
- 尚缺 AXI 64-bit write-data 到 Q/K/V physical banks 的双时钟写口/gearbox。
- 尚缺 soft reset/abort/outstanding drain、三域 reset-done start gate 和精确 CDC XDC。
- production source manifest、board/system top、PS/BD/IP 尚未修改。
- 没有 full-board synthesis、implementation、route、hold、DRC、功耗、BIT、XSA、BSP 或 ELF。

因此本检查点不是 `C-single-board` READY，不得交 D 上板，也不能开始 C3/C4。
当前回退点仍是已板测 303.120724 ms 的匹配 v3.1.4 BIT/XSA/ELF。
