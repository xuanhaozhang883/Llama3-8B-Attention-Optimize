# v2.6 Causal + Dual-Tile 集成设计

## 固定目标

```text
基线：v2.5 跨 Group Ping-Pong
频率：150 MHz（本版不提频）
QK：2 × 4×4 Tile
QK causal：整块位于上三角时跳过算术，但补发16个 masked score
Softmax→PV：原生 TILE4
PV：2 × 4×4 Tile
PV causal：逐行有效，local row i 只计算 k <= row_base+i
```

## 数据顺序约束

- 双QK同时启动相邻两个列Tile，但输出按lane 0、lane 1串行合并，外部
  坐标顺序与v2.5单QK相同。
- 跳过的QK Tile输出`BF16 -Inf (16'hFF80)`，坐标仍连续；对角Tile不
  跳过，Tile内部上三角继续由原Causal Mask处理。
- 原生TILE4 Buffer直接存储Softmax输出的4行P与4列V，不再经过
  TILE2→TILE4拼接。
- 双PV共享同一个P4向量、读取相邻两个V4向量；Context按lane 0、lane 1
  串行合并，保持v2.5 Context写回顺序。
- PV逐行有效时，4行共享输入流运行到`row_base+3`；每行独立在
  `k=row_base+i`置last并停止后续MAC。

## 配置

优化默认配置：

```text
QK_LANES=2
CAPTURE_TILE=4
PV_LANES=2
CAUSAL_QK_TILE_SKIP=1
CAUSAL_PV_ROW_EFFECTIVE=1
```

结构回退配置：

```text
QK_LANES=1
CAPTURE_TILE=2
PV_LANES=1
CAUSAL_QK_TILE_SKIP=0
CAUSAL_PV_ROW_EFFECTIVE=0
```

回退配置选择v2.5的单QK、TILE2 Adapter、单PV结构。
如果使用回退bitstream执行同一份A53程序，应为C编译器增加
`FPT_V26_EXPECT_OPTIMIZED=0`，关闭只适用于默认v2.6配置的固定计数门禁。

## 固定规模期望计数

每个GQA Group：

| 计数器 | 期望值 |
|---|---:|
| QK计算Tile | 2,112 |
| QK跳过Tile | 1,984 |
| Masked Tile发出 | 1,984 |
| PV计算Reduction term | 4,227,072 |
| PV跳过Reduction term | 4,161,536 |
| PV输入beat | 135,168 |
| 原生TILE4 Capture向量 | 524,288 |

完整8 Group运行的原生TILE4 Capture向量应为4,194,304。

## 验收边界

包内静态检查只能证明接口合同、调度数学、计数期望和主机代码语法。
正式保留v2.6必须同时满足：

1. Vivado 2024.2 RTL elaboration通过；
2. 综合/实现完成，WNS >= 0、TNS = 0、DRC无错误；
3. Vitis应用构建通过；
4. 板上预热1次、正式10次，正确性10/10、确定性10/10；
5. `Combined failures=0`，QK/PV causal error flags均为0；
6. 新计数器与上表一致；
7. 性能数据采用实测周期，不用理论减少量替代。
