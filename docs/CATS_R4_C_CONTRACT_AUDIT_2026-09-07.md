# CATS-R4 C 线 v1 契约审计（2026-09-07）

状态：`CONTRACT-ONLY / NOT READY FOR C2`

依据：`docs/CATS_R4_INTERFACE_COMMIT.md`（`CATS_R4_IF_V1`，冻结），以及当前分支 `codex/cats-r4-local-integration` 的本地候选。本文只记录当前证据，不把局部仿真或 OOC 结果提升为整板结论。

## 逐项结论

| v1 条目 | 当前证据 | 结论 | 解除条件 |
|---|---|---|---|
| Q/K/V bank mapping | `cats_r4_qkv_axi_bank_bridge.sv` 对固定线性 beat 的 Q/K/V 映射与 v1 规划可对应；`tb_cats_r4_axi64_qkv_banked_mem.sv` 已验证一个参数化 bank 模型的写读回。bridge 默认 XPM 全容量 runtime 尚未通过。 | `PARTIAL` | 用 v1 的 32 key-bank/32 feature-bank、Q 4-bank 各自做完整 bridge readback，并保存 XSim log。 |
| request 接受后第 2 个 `core_clk` 周期返回 | bridge 有 `q_p0/q_p1`、`k_p0/k_p1`、`v_p0/v_p1` 两级 valid pipeline，XPM 参数写为 `READ_LATENCY_B=2`；但当前没有通过的默认 XPM runtime readback。 | `PARTIAL / UNPROVEN` | 用真实 XPM 或等价已审计模型测量 fire 到 rsp_valid 的边沿差，覆盖连续请求和不同 active buffer。 |
| response 不支持回压 | Q/K/V response 端口没有 `ready`，`rsp_valid` 由 core pipeline 产生。 | `STRUCTURAL PASS` | 集成 wrapper 必须保证 consumer 永不丢 response；不能在下游再增加隐式回压。 |
| `EMPTY → FILLING → READY → ACTIVE → EMPTY` | 当前只有 `desc_active`、`done_valid` 和外部 `active_valid/active_buffer`，没有内部 buffer ownership/state machine，也没有 READY/ACTIVE 原子切换条件。 | `FAIL` | 在 C wrapper 中加入双缓冲 ownership token、READY 条件、ACTIVE 保护和释放条件。 |
| active buffer 写保护 | AXI 写路径没有看到 `active_buffer` 的同域保护；`wr_ready` 只检查 descriptor token、done 和 sticky error。 | `FAIL` | 增加 AXI/core ownership handshake；active buffer write 必须拒绝并计 `active_buffer_write_error`。 |
| epoch/group/buffer/beat 一致性 | descriptor 活跃期间会严格匹配 kind/buffer/epoch/group/head/window/next index；done token 回传这些字段。没有跨域 ownership token，也没有旧 epoch drop counter。 | `PARTIAL` | 接入 epoch-aware CDC FIFO，验证 mismatch、restart 和旧 completion 丢弃。 |
| 4 KiB burst boundary / short tail | bridge 只有 `wr_beat_index`，没有 AXI byte address、burst length 或 boundary split；固定 Q=512、K/V=4096 beat，`wr_last` 只按固定末 beat 检查。 | `FAIL` | 在 descriptor/DMA 层实现 `min(256, remaining, beats_to_4KiB)`，并测试边界、短尾和 `boundary_split` counter。 |
| reset/abort 后旧 epoch 丢弃并计数 | 当前只有 `axi_rst_n/core_rst_n`，没有 abort 输入、epoch 递增逻辑或 `epoch_drop` counter；done 也不跨域。 | `FAIL` | 增加 soft-reset/abort 流程，先停 descriptor，再清 FIFO/ownership，旧 epoch completion 必须丢弃并计数。 |
| C 侧 counter 闭合 | 当前 bridge 公开 `q_beats_accepted/k_beats_accepted/v_beats_accepted/protocol_errors`；没有 `rd_beats/wr_beats/rows_committed`、FIFO、DMA、output、conflict 计数器。 | `FAIL` | 由 owner domain 累加并 snapshot，闭合 `rd_beats=196608`、`wr_beats=131072`、`rows_committed=4096`，其余错误计数全为 0。 |

## 当前可以可信复用的证据

- bridge protocol-only 仿真：Q=512、K=4096、V=4096 beat 连续 descriptor、done token、累计计数、提前 `wr_last` 负向门禁通过。
- 参数化 `cats_r4_axi64_qkv_banked_mem` 直接仿真：双缓冲写入、Q/K/V bank expansion、跨 axi/core 时钟读回、非法对齐计数通过。
- bridge synthesis-only OOC：0 errors、0 critical warnings、setup WNS `+3.372 ns`；不代表 place/route、hold、DRC、full-board 或 BIT/XSA/ELF。

## Contract-only 验证包范围

已纳入/应纳入本阶段的测试分为两类：

1. **可在当前候选上直接验证**：Q/K/V bank expansion、descriptor token/beat sequence、done backpressure、premature last、token mismatch、sticky protocol error、参数化跨时钟读回。
2. **必须保留为 NOT READY 门禁**：active-buffer write protection、buffer lifecycle、4 KiB split/short tail、abort/epoch drop、CDC ownership FIFO、output reorder/FIFO backpressure、aggregate DMA/output counter closure。

## 2026-09-07 增量复核

- 新增 `tb/xpm_memory_sdpram_model.sv`（仅 Icarus contract test 使用，不替代 Vivado `xpm` library）。默认 bridge 路径现在完成 Q/K/V readback，并对三路 request fire→response valid 做两 `core_clk` 周期断言。
- 复核发现原 XPM `READ_LATENCY_B=2` 与 bridge 的两级 response pipeline 存在 payload/valid 错位；将内部 XPM read latency 调整为 1，保持 wrapper 对外仍为固定第 2 个 `core_clk` 周期响应。该修正需在 Vivado XPM/OOC 重新确认后才能提升证据等级。
- protocol-only TB 新增 reset 清 sticky stop 和 descriptor token mismatch 负向门禁；`tests/run_cats_r4_c_contract_only.ps1` 已串联 protocol、默认行为模型 readback、参数化 bank mapping 三个 case，全部通过。
- 本轮没有实现 active-buffer protection、buffer lifecycle、4 KiB split/short tail、abort/epoch-drop、CDC ownership FIFO 或 aggregate DMA/output counters；这些仍保持 `FAIL / NOT READY`。
## C2 入口判定

当前不能进入 C2 full integration。只有 A READY、B READY、compute cluster wrapper READY 和本审计中所有 `FAIL` 项补齐后，才可在全新短 ASCII build root 运行 150 MHz full-board synthesis/implementation/Timing/DRC。150 MHz 全门禁通过前，不启动 200 MHz，也不生成 BIT/XSA/ELF。
