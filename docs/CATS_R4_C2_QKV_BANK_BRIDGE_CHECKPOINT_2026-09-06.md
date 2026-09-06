# CATS-R4 C2 Q/K/V AXI bank bridge 检查点

状态：`LOCAL CHECKPOINT / NOT READY / DO NOT BOARD TEST`

日期：2026-09-06（Asia/Shanghai）

## 本次推进

在不改变生产 manifest、board top 或 v3.1.4 fallback 的前提下，完成候选 AXI 64-bit → Q/K/V physical-bank bridge 的可综合性检查：

- `rtl/core/cluster/cats_r4_qkv_axi_bank_bridge.sv` 保持为未纳入 manifest 的候选实现；AXI 写端按 64-bit beat 接收，Q/K/V 分别映射到双缓冲物理 bank，core 读端保持两拍响应接口。
- `scripts/cats_r4_qkv_axi_bank_bridge_ooc.tcl` 已修为参数化 source/output root、150 MHz 双时钟约束和可复现 Vivado project/OOC 入口。
- `tb/tb_cats_r4_axi64_qkv_banked_mem.sv` 修复了测试任务中使用保留字 `buf` 导致的编译错误；直接 banking test 通过。
- bridge 中 `q_enb/k_enb/v_enb` 的重复组合驱动已移除，避免综合多驱动网。

## 验证证据

### 直接仿真

```text
iverilog -g2012 -Wall -s tb_cats_r4_axi64_qkv_banked_mem ...
vvp c2_axi64_mem.vvp
PASS CATS_R4 AXI64 Q/K/V dual-clock bank expansion
```

覆盖 Q ping/pong、K key-bank、V feature-bank 写入，跨 axi/core 异步时钟读取，以及非法对齐写计数。

### Vivado OOC

- 工具：Vivado 2025.2 SW Build 6299465
- 器件：`xczu15eg-ffvb1156-2-i`
- 约束：axi_clk/core_clk 均为 150.015 MHz；两域异步分组；端口 I/O delay 已写入独立 XDC。
- 输出根：`D:/Vitis/FPT/c2_qkv_bridge_ooc_20260906_r4`
- `synth_design`：0 errors，0 critical warnings，27 warnings
- setup worst slack：`+3.372 ns`；setup failing endpoints=0；unconstrained internal endpoints=0
- 资源（synthesis-only OOC）：2,052 LUT，1,423 FF，100 BRAM tiles，0 DSP，0 URAM
- CDC 报告已生成；OOC 不代表 placed/routed hold、DRC、功耗或整板结果。

## 尚未解除的门禁

- A/B READY 单元、计算 cluster wrapper、shared HP0 descriptor arbiter、三域 reset-done/start gate 和 full-board integration 仍不存在或未闭合。
- bridge 仍未进入 `scripts/source_manifest.tcl`，没有修改 board/system top。
- XPM RAM 内置 `rsta/rstb` 当前保持未连接；Vivado 只报告 warning。外部 reset/ownership 语义必须在后续集成 wrapper 中明确，不能以本 OOC 结果替代 CDC/reset 验证。
- 因此本检查点仍是 NOT READY，不得生成或交付 C2 BIT/XSA/ELF，也不得进行板测。

当前正式回退点仍为已板测 v3.1.4 causal-bypass 匹配 BIT/XSA/ELF（303.120724 ms，10/10 correct、10/10 deterministic，误差门禁通过但非 bit-exact）。
## 后续结构检查

新增 `tb/tb_cats_r4_qkv_axi_bank_bridge.sv` 后，Vivado XSim 已完成 VRFC 分析、静态 elaboration 和 snapshot 构建；此前共享循环变量错误已不再出现。完整 runtime 在 XPM 136 个双缓冲 RAM 初始化阶段长时间无时间推进，本轮已停止该进程，不能记为 runtime PASS，也未据此放宽门禁。

循环变量修复后的 Vivado OOC 复核输出根为 `D:/Vitis/FPT/c2_qkv_bridge_ooc_20260906_r7`，结果仍为 0 errors、0 critical warnings，setup worst slack `+3.372 ns`。该结果仍仅是 synthesis-only OOC。
## 邻接组件回归

在本轮候选修改后重新运行：

- `tb_cats_r4_cluster_shell`：PASS
- `tb_cats_r4_q_slab_dma_controller`：PASS（256 descriptors / 131072 beats / 512 bursts）
- `tests/test_cats_r4_c1_capacity_model.py`：PASS（使用文件自带入口；当前 Python 环境未安装 pytest）

这些结果只证明相邻基础组件未出现回归，不改变 bridge 尚未进入生产集成和整板门禁未解除的结论。
本轮另行回归：

- `tb_cats_r4_qkv_banked_mem`：PASS（IF_V2 ownership、32 slabs、N+2/II1）
- `tb_cats_r4_slot_bank`：PASS（collision / owner / backpressure）
## 可重复桥接协议门禁

新增 `tests/run_cats_r4_qkv_axi_bank_bridge_vivado.ps1`，从空输出目录依次执行两条互补验证：

1. `CATS_R4_PROTOCOL_ONLY`：只保留 AXI 描述符状态机，不展开 RAM/core 读服务；以连续 `valid`、II=1 的 burst 完整发送 Q=512、K=4096、V=4096，共 8,704 个 beat。三个 done token、累计计数和零错误检查通过。
2. 负向协议门禁：额外接受一个 `wr_beat_index=0` 且提前 `wr_last=1` 的 Q beat；验证 `protocol_errors=1`、sticky error 置位、`done_valid=0`、`wr_ready=0`，且该已接受错误 beat 计入 Q counter。
3. 默认宏未定义路径：使用 `-L xpm` 完成 VRFC、static elaboration、data-flow analysis 和 snapshot 构建，证明测试宏没有掩盖 XPM 结构错误。

可重复验证输出根：`D:/Vitis/FPT/c2_qkv_bridge_verify_20260906_r1`。协议仿真结束于 34.859 us，包含 `NEGATIVE_GATE_DONE` 与最终 PASS 标记。

完整读回测试中的 K 期望地址已纠正：`key_block=1,d=7` 时，bank 0 / bank 31 对应输入 beat 1025 / 2017，不是 1031 / 2023。默认 XPM 全容量 runtime 仍未获得 PASS；当前协议 PASS 不包含 RAM 数据读回，不能替代 `tb_cats_r4_axi64_qkv_banked_mem` 的 banking 检查或后续整板验证。

## 默认 XPM OOC 复核 r8

输出根：`D:/Vitis/FPT/c2_qkv_bridge_ooc_20260906_r8`。

- Vivado 2025.2 `synth_design`：0 errors，0 critical warnings，27 warnings。
- 资源：2,052 CLB LUT、1,423 FF、64 RAMB36E2 + 72 RAMB18E2（合计 100 BRAM tiles）、0 DSP、0 URAM。
- setup WNS：`+3.372 ns`；setup failing endpoints=0；脉宽 failing endpoints=0。
- 仍有 OOC `HD.CLK_SRC` 缺失、XPM `rstb` 未连接和仅综合态 CDC 报告等已知限制；没有 place/route hold、整板 DRC、功耗或 BIT/XSA/ELF 证据。

因此该候选仍为 `LOCAL CHECKPOINT / NOT READY / DO NOT BOARD TEST`。
