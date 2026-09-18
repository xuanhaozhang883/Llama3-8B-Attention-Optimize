# D3 前置消融与 CATS-R4 入口审计

日期：2026-09-10  
职责：D / 独立验证  
结论：**旧版本 causal-bypass 消融 PASS_WITH_LIMITATIONS；CATS-R4 正式 row/online D3 BLOCKED_AT_ENTRY_GATE。**

## 1. 结论先行

当前可以确认一个变量清楚、已有板测证据的消融：

`v3.1.3 legacy consumer -> v3.1.4 causal consumer bypass`

v3.1.4 在相同 150 MHz 口径下，把平均 Total PL cycles 从 `63,669,978`
降到 `45,467,520`，减少 `18,202,458` cycles（`28.588761%`），加速
`1.40034x`。报告延迟从 `424.471607 ms` 降到 `303.120724 ms`，减少
`121.350883 ms`。

但这不是新的 CATS-R4 row/online 消融。GitHub 现有证据显示：A2 单元/OOC
已 READY，B2/B3 和 A+B+C production wrapper 仍未交付，C 的发布门禁仍为
`NOT_READY`。因此不能用旧 `agent/online-softmax-context-v3` 分支冒充新的
CATS-R4 online 对照，也不能把 A2 row handoff 当成完整 row Softmax/PV。

## 2. GitHub 分支与门禁审计

通过 GitHub 读取了仓库 `xuanhaozhang883/Llama3-8B-Attention-Optimize` 的
分支列表、main 最新提交和以下交付文件：

- `main`：`35397958107bb552453bf81858bc25847a8dcffd`，仍是 2026-09-07 的旧集成。
- `agent/cats-r4-a2-row-handoff`：A 的 2026-09-10 交付声明
  **A unit/OOC READY；production integration NOT READY**。
- A2 technical evidence SHA：`051559ef1edf03e7b3aeed9010c1b4c5bfa577a5`。
- A 文档记录的远端 HEAD：`91984c47747ae2d282529574a29c59930d0f6c57`；
  文档生成后分支可能继续前进，因此正式审查时仍须重新解析实际 HEAD。
- `codex/cats-r4-local-integration`：本地已知远端 ref
  `132be510032fd78b90978f24e72d2bafaac59ec0`；其 GitHub
  `CATS_R4_RELEASE_GATE.json` 仍为 `overall=NOT_READY`。
- GitHub 当前分支列表没有可审查的 CATS-R4 B2/B3 新分支；
  `agent/online-softmax-context-v3` 是 2026-08-01 的旧 online 实现，且落后 main。

正式 D3 row/online 缺少：

1. B2 整行 Softmax 的源码 SHA、full/stress/反压、exp/sum counter 和 OOC；
2. B3 32-lane PV、归一化、`33,816,576` PV MAC、`524,288` Context words 和 OOC；
3. A3 单 cluster 三槽 compute wrapper；
4. C memory-service 与同一 wrapper 的集成证据；
5. 同输入、同精度、同 QK/PV lanes、同频率、同计时边界的 row/online 两个可运行候选。

所以当前正式状态必须是 `BLOCKED_AT_ENTRY_GATE`，不是 D3 READY。

## 3. 本轮实际执行的可用消融

### 3.1 固定身份

| 角色 | 固定提交/证据 | 用途 |
|---|---|---|
| v3.1.3 代码基线 | `c7f888bad26bf621f7415f3cd49f2c8a2a1c58b7` | 独立 worktree、full-GQA 重跑 |
| v3.1.4 代码候选 | `fa726db7e834aefbfc91593b1348c3a4cf8d6279` | causal bypass 单变量实现、full-GQA 重跑 |
| v3.1.4 板级产物提交 | `84a69f707070cb2f3c583642d4cf470552e174da` | routed BIT/XSA/ELF 身份链 |
| v3.1.4 原始板测 | `Serial_Debug_2026-09-04_201742.txt` | warm-up + 10 measured runs |

代码变量位于 `flash_attention_consumer_top.sv`：对满足
`all_masked && col_tile > row_tile` 的 causal tile 在 consumer 入口直接握手
旁路，且新增 bypass counter/error；QK 计算口径、有效 Context 数量和数值模型不变。

### 3.2 公平性口径

| 条件 | v3.1.3 | v3.1.4 | 判定 |
|---|---|---|---|
| workload | full GQA：32 heads x 128 rows x 128 features | 相同 | 一致 |
| 输入来源 | authoritative v3.0 `vitis/data` board vectors | 相同 | 一致 |
| 数值模型 | RTL-exact tile model，tile=4 | 相同 | 一致 |
| QK lanes | 4 | 4 | 一致 |
| 频率 | 150 MHz 报告口径 | 150 MHz 报告口径 | 一致 |
| 计时边界 | Total PL cycles | Total PL cycles | 一致 |
| 单一变化 | legacy consumer 处理全部 32768 tiles | consumer 跳过 15872 个全 masked causal tiles | 可归因 |

注意：缺少本地 v3.1.3 原始 UART/BIT/XSA/ELF 包；基线周期来自已冻结的
D1 签核契约。故性能结论可复算，但本目录不能声称完成了两套产物的重新上板。

## 4. 结果

### 4.1 正确性

两套固定代码提交均重新执行 full-GQA Python 数值模型：

| 指标 | v3.1.3 | v3.1.4 |
|---|---:|---:|
| elements | 524,288 | 524,288 |
| evaluated rows | 4,096 | 4,096 |
| combined_failures | 0 | 0 |
| different（非 bit-exact） | 223,988 | 223,988 |
| strict_abs_failures | 3 | 3 |
| max_abs_error | 0.0001220703125 | 0.0001220703125 |
| max_ulp | 28,309 | 28,309 |

两份数值 JSON 的 SHA-256 完全相同：
`16B7A9C62974B31FA22CB0CB8762756F9401B43F3DC6E37F87846737EFA476DB`。
这符合预期，因为该软件模型验证数值路径，不模拟 causal bypass 的控制周期；
不能用 JSON 相同替代 RTL bypass 验证。

两套提交各自的 board-log 签核器单测均为 `3/3 PASS`。

v3.1.4 原始 UART 使用明确的 `v314-causal-bypass` profile 重新签核：

- warm-up：PASS；
- correct：10/10；deterministic：10/10；
- combined failures：每次 0；
- 所有错误标志：0；
- Total PL cycles min/avg/max：`45,467,489 / 45,467,520 / 45,467,586`。

同一日志用默认 `legacy-v313` profile 会按预期 FAIL：它要求 processed
tiles=32768，而日志为 16896。负向日志已保留，证明 profile 没有被静默混用。

### 4.2 性能与工作量消融

| 指标 | v3.1.3 | v3.1.4 | 变化 |
|---|---:|---:|---:|
| avg Total PL cycles | 63,669,978 | 45,467,520 | -18,202,458（-28.588761%） |
| 报告延迟 | 424.471607 ms | 303.120724 ms | -121.350883 ms |
| speedup | 1.00000x | 1.40034x | +40.034% |
| consumer tiles processed | 32,768 | 16,896 | -15,872（-48.4375%） |
| causal tiles bypassed | 0 | 15,872 | +15,872 |
| V vectors read | 2,097,152 | 1,081,344 | -1,015,808（-48.4375%） |
| Context words | 524,288 | 524,288 | 不变 |
| QK computed/skipped | 16,896 / 15,872 | 16,896 / 15,872 | 不变 |

结论：周期收益与 consumer/V 工作量减少方向一致，且没有混入 QK lane 增加、
cluster 复制或升频，因此可以归因于 causal consumer bypass。

### 4.3 PPA、时序与产物

v3.1.4 已归档的 full-board routed 证据：

- Vivado 2025.2，`xczu15eg-ffvb1156-2-i`；
- 150.015 MHz，WNS/TNS `+0.654 / 0.000 ns`，WHS/THS `+0.010 / 0.000 ns`；
- Fully Routed，DRC 0 Error；
- LUT 66,866，FF 124,824，BRAM36 97，DSP 400，URAM 0；
- vector-less 估算功耗 4.850 W（Medium confidence，不是实测功耗）；
- BIT/XSA/ELF 哈希见 `P2C_ARTIFACT_MANIFEST_2026-09-04.json`。

本目录没有匹配的 v3.1.3 full-board utilization/timing 原始报告，故不计算
PPA delta，也不声称资源消融完成。

## 5. 本轮执行矩阵

| 检查 | v3.1.3 | v3.1.4 | 证据等级 |
|---|---|---|---|
| full-GQA Python | PASS | PASS | 本轮实跑 |
| Python signoff unittest | 3/3 PASS | 3/3 PASS | 本轮实跑 |
| v3.1.4 UART signoff | N/A | PASS | 本轮对原始日志重放 |
| 错误 profile 负向检查 | N/A | expected FAIL | 本轮实跑 |
| Icarus RTL | NOT RUN：工具未找到 | NOT RUN：工具未找到 | 不冒充失败 |
| XSim/OOC/full-board | NOT RERUN | NOT RERUN | 仅引用归档证据 |
| 两版重新上板 | NOT RUN | NOT RUN | 缺板卡/成对产物 |

`v313_system_checks.log` 中的退出码来自工具缺失，测试在 QK4 配置检查 PASS 后、
进入 RTL 编译前停止；它不是设计 FAIL。

## 6. 最终判定与下一入口

- `v3.1.3 -> v3.1.4 causal bypass`：`PASS_WITH_LIMITATIONS`。
- CATS-R4 A2：可进入 D 的独立单元审计，但 A 的 full-size score golden 仍是
  `CANDIDATE_NOT_FROZEN`。
- CATS-R4 正式 row/online D3：`BLOCKED_AT_ENTRY_GATE`。

解除正式 row/online 阻塞的最小交付是：B2 READY SHA + B3 READY SHA + A3
single-cluster wrapper SHA + C memory-service 集成 SHA，并为 row/online 各给出
同一输入 hash、同一 numeric mode、相同 lanes/频率/计时边界的 runner、raw log、
counter、OOC PPA/WNS。收到后 D 才能运行正式 D3 并输出 READY/NOT READY。
