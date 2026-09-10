# C 侧接口与证据矩阵

状态：2026-09-10 更新。本文是 C 单元的当前矩阵，不把单个 bridge 当成整个 C memory-service。冻结基线仍为 `CATS_R4_INTERFACE_COMMIT`、`CATS_R4_INTERFACE_V2.md` 和 `CATS_R4_INTERFACE_V3.md`。

## 当前实现与证据

| 能力 | 当前权威实现 | 当前证据 | 状态 | 边界 |
|---|---|---|---|---|
| Q/K/V AXI descriptor 与 token | `rtl/core/cluster/cats_r4_qkv_axi_bank_bridge.sv` | Icarus protocol/readback、Vivado XSim default-XPM + real-XPM | PASS（单元） | 尚未接入 compute wrapper/DDR system |
| Q/K/V bank mapping | `cats_r4_axi64_qkv_banked_mem.sv` | 4 Q banks、8 K/V bank expansion、dual-clock 回归 | PASS（单元） | 32 bank 全系统 ownership 尚未集成 |
| Q slab DMA | `cats_r4_q_slab_dma_controller.sv` + splitter | 256 descriptors、131072 beats、512 bursts；OOC WNS +3.420 ns | PASS（单元） | 尚未接入完整 scheduler/DDR |
| Q/K/V 生命周期与 active-write rejection | `cats_r4_qkv_banked_mem.sv`、`cats_r4_slot_bank.sv` | ownership、overwrite、epoch、outstanding 回归 | PASS（单元） | 仅 IF_V2 局部服务 |
| IF_V3 weight slab | `cats_r4_weight_slot_mem.sv` | 4096 rows ×128 writes/reads，N+2，三槽 READY 仲裁、反压、release drain | PASS（单元） | 尚未接入 B/A wrapper；内部是 3 个逻辑 128×33 分布式 RAM |
| output CDC | `cats_r4_output_cdc.sv` | 4096 rows + reset/backpressure/wrap；payload 131072 beats，tag 4096 | PASS（单元） | 仍需与全局 reorder/DDR writer 集成 |
| output CDC OOC/CDC | `scripts/cats_r4_output_cdc_ooc.tcl` | WNS +3.629 ns，check_timing 0，methodology 0，无 Critical CDC；4 条 Gray CDC-6 warning | PASS（OOC） | warning 是受 ASYNC_REG 保护的 Gray 总线，需系统级复核 |
| soft abort/drain/epoch | `cats_r4_abort_drain_controller.sv` | 三时钟异步回归：隔离→双域 drain→双 clear→epoch++→completion backpressure→hard reset | PASS（单元） | 未接入 production reset/AXI outstanding 实体 |
| abort/drain OOC/CDC | `scripts/cats_r4_abort_drain_ooc.tcl` | WNS +4.941 ns，check_timing 0，methodology 0，8 条 CDC-3 Info，无 Critical | PASS（OOC） | 仍需集成 reset controller 与真实 outstanding 计数 |

## C 单元统一门禁

权威入口：

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_cats_r4_c_unit_checks.ps1
powershell -ExecutionPolicy Bypass -File tests/run_cats_r4_c_vivado_checks.ps1 -VivadoRoot D:\Vitis\2025.2\Vivado
```

最近一次结果：

- Icarus：`[PASS] CATS-R4 C unit suite: 15 protocol/memory/DMA/CDC/output/reset/v3-weight cases`；
- Vivado/XSim/OOC：`[PASS] CATS-R4 C Vivado suite: two vendor runtimes and five clean 150 MHz OOC gates`；
- 统一输出目录：`C:\Users\Lenovo\AppData\Local\Temp\c4vg_0910_all_final`；
- 代码基线：第一批提交 `0c69bcf`；第二批 output/FIFO/abort 改动提交为 `f807b93cd2a877001005c37bdd35cb25dc6afbe2`；
- 工具：Vivado/XSim 2025.2，Icarus/ vvp。

## 尚未闭合的 C 系统门禁

以下事项不能由上述单元结果代替：

1. IF_V2 Q/K/V buffer、IF_V3 weight service、A/B row handoff 和 compute wrapper 的真实端口集成；
2. 全系统正常计数闭合：`rd_beats=196608`、`wr_beats=131072`、`rows_committed=4096`；
3. integrated output reorder→DDR writer 的 canonical order、BRESP/RRESP、全局 backpressure；
4. production reset controller 接入 abort/drain 控制器并连接真实 AXI outstanding；
5. full C2 single-cluster 150 MHz elaboration、synthesis、implementation、route、DRC、board/XSA/ELF；
6. production manifest 尚未修改，C 仍为 `IN PROGRESS / NOT READY`。

历史 `CATS_R4_C_PROTOCOL_EVIDENCE_2026-09-08.md` 保持 protocol-only 证据，不覆盖本文最新矩阵。
