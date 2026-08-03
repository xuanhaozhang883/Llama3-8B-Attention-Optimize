# FPT XCZU15EG Attention 优化汇总

> 平台：AMD/Xilinx XCZU15EG-FFVB1156-2-I | Vivado/Vitis 2024.2
> 负载：LLaMA3-8B GQA Attention · 32Q/8KV · SEQ=128 · HEAD_DIM=128 · BF16
> 测量范围：START MMIO pulse → DONE · 预热 1 次 + 正式 10 次

---

## 性能演进

| 版本 | 延迟 (ms) | PL 周期 (M) | vs v2.3 | 关键改动 |
|---:|---:|---:|---:|---|
| v2.3 | 1843.7 | 276.6 | 1.00× | 8 Group 完整链路，基线 |
| v2.4 | 1843.7 | 276.6 | 1.00× | 加 Profiling 计数器（数值通路不变） |
| v2.5 | 1144.8 | 171.7 | 1.61× | 跨 Group Ping-Pong 双缓冲 |
| **v2.6** | **430.0** | **64.5** | **4.29×** | 双 Tile + Causal Skip + 原生 TILE4 |
| **v3.0** | **429.394** | **64.408** | **4.29×** | Online Softmax 跨行隔离与精确分母，实板 10/10 |

```
v2.3 ████████████████████████████████████████ 1844ms
v2.5 ██████████████████████████ 1145ms (×1.61)
v2.6 ██████████ 430ms (×4.29)
v3.0 ██████████ 429.394ms (×4.29，发布版)
```

---

## v2.5：跨 Group Ping-Pong 双缓冲

### 优化点

B+C（前半段）和 PV（后半段）在**相邻 Group 之间重叠执行**。

### 之前（v2.4 串行）

```
Group 0 │══ B+C ══│══ PV ══│
Group 1                │══ B+C ══│══ PV ══│
        ← B+C/PV overlap = 0 →
```

### 之后（v2.5 流水）

```
Bank A │ Group 0 B+C → Repack → Group 0 PV │
Bank B │       Group 1 B+C → Repack → Group 1 PV │
        ← 重叠执行 →
```

### 关键设计

| 组件 | 作用 |
|---|---|
| 双 Bank P/V Buffer | 乒乓存储相邻 Group 的中间结果 |
| 调度器解耦 | B+C Group ID 与 PV Group ID 独立控制 |
| Context 绑定 PV Group | DDR 写回顺序跟随 PV，保证正确 |

### 性能提升

| 指标 | v2.4 | v2.5 | 提升 |
|---:|---:|---:|---:|
| 平均延迟 | 1843.7 ms | 1144.8 ms | **-37.9%** |
| PL 总周期 | 276.6M | 171.7M | **-37.9%** |
| B+C/PV 重叠 | 0 | 104.8M (61%) | 新增 |
| Real-PV feed stall | 115.6M (41.8%) | 76.6M (44.6%) | — |

---

## v2.6：双 Tile + Causal Skip + 原生 TILE4

在 v2.5 Ping-Pong 框架上叠加五项 Group 内部优化：

---

### 优化 ①：双 4×4 QK Tile

**做法**：沿 column tile 方向部署两个 4×4 QK Systolic Tile 并行计算。

```
单 Tile (v2.5)              双 Tile (v2.6)
K 列 0~3   → Tile A         K 列 0~3  → Tile A ┐
K 列 4~7   → Tile A         K 列 4~7  → Tile B ├ 同时
K 列 8~11  → Tile A         K 列 8~11 → Tile A ┤
K 列 12~15 → Tile A         K 列 12~15→ Tile B ┘
```

**设计决策**：共用单套 RoPE Q/K Cache 读端口（轮询仲裁），不增加存储。

> 不采用单 8×8 Tile（DSP×4 时钟难收）或复制整个 Group 通路（BRAM 超 25% 保护线）。

**提升**：QK 算力翻倍。

---

### 优化 ②：Causal QK Whole-Tile Skip

**做法**：Tile 级因果判断——整个 4×4 Tile 位于上三角时，**零周期跳过** QK 算术，直接补发 BF16 -Inf 得分。

```
QK 矩阵 (32 Tiles × 32 Tiles)
       K →
  Q  ┌──────────────────┐
  ↓  │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  跳过 1984 个 Tile
     │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
     │    ▓▓▓▓▓▓▓▓▓▓▓▓▓│
     │      ▓▓▓▓▓▓▓▓▓▓▓│  计算 2112 个 Tile
     │  ████  ▓▓▓▓▓▓▓▓▓│  (对角 Tile 内因果 Mask 保留)
     │  ██████  ▓▓▓▓▓▓▓│
     └──────────────────┘
```

**创新**：不是逐元素 mask，而是 Systolic Array 的 **Tile 粒度零开销跳过**。输出坐标连续，下游 Softmax 无感。

**提升**：跳过 1984/4096 = **48.4%** 的 QK Tile。

---

### 优化 ③：原生 TILE4 Capture

**做法**：Softmax → PV 数据路径从 TILE2→Adapter→TILE4 改为直接原生 TILE4。

```
v2.5: Softmax → [TILE2] → [拼成TILE4] → PV Buffer
v2.6: Softmax → [TILE4] ──────────────→ PV Buffer
```

**提升**：消除 Repack 拼接等待，减少 Softmax→PV 的 stall。

---

### 优化 ④：双 4×4 PV Tile

**做法**：与 QK 对称，两个 PV Tile 沿 head_dim 方向并行。P4 广播，V4 分发给 Tile A/B。

**提升**：PV 算力翻倍。

---

### 优化 ⑤：Causal PV 逐行有效

**做法**：PV 每次算 4 行，每行独立控制在 `k <= row_base + i` 处停止。

```
k:   0  1  2  3  4  5  6  7  8 ...
─────────────────────────────────
行0: ●  ●  ●  ●  ●  ●  ●  ●  ●  (k ≤ row+0, 全有效)
行1: ●  ●  ●  ●  ●  ●  ●  ●  ●  (k ≤ row+1, 全有效)
行2: ●  ●  ●  ●  ●  ●  ●  ○  ○  (k ≤ row+2, 停止)
行3: ●  ●  ●  ●  ●  ●  ●  ●  ○  (k ≤ row+3, 停止)
                                ↑ 流结束
```

每行独立 `first`/`last` 信号 + `in_row_enable`，精确到单列。

**提升**：跳过 4,161,536/8,388,608 = **49.6%** 的 PV 乘加项。

---

### v2.6 整体性能

| 指标 | v2.5 | v2.6 | 改善 |
|---:|---:|---:|---:|
| 平均延迟 | 1144.8 ms | **430.0 ms** | **-62.4%** |
| PL 总周期 | 171.7M | **64.5M** | **-62.4%** |
| 稳态 Group 间隔 | 19.58M | **7.54M** | **-61.5%** |
| 有效算力 | — | **0.624 GFLOP/s** | — |
| B+C/PV 重叠率 | 61.0% | 44.7% | 重叠绝对值降但总周期压缩更多 |

---

## 固定计数验证

| 计数器 | 预期值 | 实测值 | 状态 |
|---:|---:|---:|:---:|
| QK Tile 计算 / Group | 2,112 | 2,112 | ✅ |
| QK Tile 跳过 / Group | 1,984 | 1,984 | ✅ |
| Masked Tile 补发 / Group | 1,984 | 1,984 | ✅ |
| PV 乘加项 计算 / Group | 4,227,072 | 4,227,072 | ✅ |
| PV 乘加项 跳过 / Group | 4,161,536 | 4,161,536 | ✅ |
| 原生 TILE4 向量 / Run | 4,194,304 | 4,194,304 | ✅ |

---

## 消融分析：各优化独立贡献

| 优化 | 机制 | 累积加速比 (vs v2.4) |
|---|---|---|
| v2.4 基线 | 串行执行 | 1.00× |
| + v2.5 Ping-Pong | 跨 Group B+C/PV 流水重叠 | **1.61×** |
| + 双 QK Tile | QK 算力翻倍 | — |
| + Causal QK Skip | B+C 跳过 48% Tile | — |
| + 原生 TILE4 | 消除 Repack 开销 | — |
| + 双 PV Tile | PV 算力翻倍 | — |
| + Causal PV Row | PV 跳过 50% 乘加 | — |
| **v2.6 全部** | **五项叠加** | **4.29×** |

```
加速因子分解：
v2.5 Ping-Pong (1.61×) × v2.6 Group内优化 (2.66×) ≈ 4.29×
```

---

## 资源与时序

| 指标 | v2.5 | v2.6 | 变化 |
|---:|---:|---:|---:|
| WNS @ 150 MHz | +1.119 ns | +0.801 ns | -0.318 ns |
| TNS | 0 | 0 | — |
| LUT | 19,613 | 35,184 | +79.4% |
| BRAM Tile | 175.5 | 175.5 | 0% |
| DSP | 136 | 267 | +96.3% |

- 双 Tile 的主要代价是 LUT（控制逻辑翻倍）和 DSP（PE 翻倍）
- BRAM 完全不变（双 Tile 共享存储）
- 时序余量从 1.119ns 降至 0.801ns，仍在安全范围，有提频空间

---

## 正确性

| 指标 | 结果 |
|---|---|
| 正确运行 | 10 / 10 |
| 确定性运行 | 10 / 10 |
| Combined failures | 0 |
| Error detail bitmap | 0x00000000 |
| Causal error flags | 0x00000000 |
| Strict abs failures | 7（全部 1 ULP 救回） |
| Exact mismatches | 225,853 / 524,288 |

错误分布与 v2.4 基线一致，证实双 Tile 和 Causal 优化**未改变数值通路**。

---

## 剩余瓶颈（v2.6 Profiling）

| 瓶颈 | 周期 | 占比 | 说明 |
|---:|---:|---:|---|
| B+C busy | 60.3M | 93.5% | B+C 仍是稳态上限 |
| **Real-PV feed stall** | **31.9M** | **49.4%** | PV 等待 Softmax 输出，最大剩余瓶颈 |
| QK busy | 37.3M | 57.8% | QK 计算仍占 B+C 多数时间 |
| B+C/PV overlap | 28.8M | 44.7% | 重叠率可进一步提升 |
| DDR read | 0.4M | 0.6% | 非瓶颈 |
| DDR write | 0.2M | 0.2% | 非瓶颈 |
| Softmax 本体 | 5.0M | 7.7% | 非瓶颈 |

**下一步方向**：继续压缩 B+C（进一步并行 QK 或扩展 Softmax）、降低 PV feed stall（提前 Softmax 输出供给）。

---

## 架构创新要点

1. **Tile 级 Causal Skip** — 在 Systolic Array 的 Tile 粒度做因果判断，整个 Tile 跳过算术，非逐元素 mask。QK 跳过 48%、PV 跳过 50% 无用计算。

2. **跨 Group Ping-Pong 流水** — 利用 GQA 的 Group 自然边界做流水级，B+C 和 PV 跨 Group 重叠。Profiling 驱动的优化（从 v2.4 数据发现 overlap=0）。

3. **双 Tile 共享存储** — 两套 4×4 PE 阵列共享一套 RoPE Cache 和 P/V Buffer，算力翻倍但存储不增。避免了 8×8 Tile 的时序风险和 Group 复制的资源开销。

---

## v3.0 发布结论

v3.0 不改变 v2.6 的 Dual-Tile 主体架构，重点完成 Online Softmax 跨行状态隔离和精确分母路径。最终在 Vivado 2024.2 下满足时序与 DRC，并在 XCZU15EG 上完成 10 次正确性及确定性验证；Combined failures 为 0，最大误差为 1 ULP。

*文档更新日期：2026-08-03 · 基于 v3.0-online-softmax-exact-denominator-board-pass*
