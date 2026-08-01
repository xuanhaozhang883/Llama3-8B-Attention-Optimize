# Attention RTL 串行演进与成熟提交规范

## 1. 唯一主线

权威板级基线固定为：

```text
fpt_xczu15eg_attention/
├── rtl/core/       # Gate 0 冻结 44 个 Attention Core RTL
├── rtl/board/      # XCZU15EG 板级封装
├── mem/            # RoPE/Softmax ROM
└── tests/          # 串行 Gate 入口
```

远端 `main` 的 v2.4 Legacy 版本已有 XCZU15EG 实体板记录。本轮开发使用
Vivado 2025.2 做复现检查；在队友重新上板前，任何新版本都只标记为
“仿真通过/板级可综合”，不能替代既有板测记录。

`PACKAGE_MANIFEST.json` 是原 v2.4 上板归档的历史清单，不作为本开发分支的实时
文件清单。Gate 复现身份以 Git commit、测试入口和生成的 `gate0_summary.json`
为准；打包脚本明确排除 `build/`，不会把 XSim/Vivado 生成物装入源码归档。

## 2. 固定执行顺序

| Gate | 唯一改动主题 | 接入范围 | 必须通过后才能进入下一 Gate |
|---|---|---|---|
| 0 | Reproducible Legacy baseline | 不改数据通路 | 全链路 XSim、主机契约、板级 RTL elaboration |
| 1 | Online Softmax Golden | 仅 Golden/向量/误差规范 | bit-accurate 单元回归、Legacy Gate 0 全回归 |
| 2 | Streaming Context accumulator | 独立 RTL，不接板级默认路径 | Golden 对拍、握手/清空/边界、OOC 综合、Gate 0/1 |
| 3 | 四 Head KV Tile 广播 | 独立 RTL，连接 Gate 2 的测试系统 | 四 Head 同源、顺序/计数/背压、OOC 综合、Gate 0~2 |
| 4 | Legacy/Streaming 双模式 | 首次接入系统顶层，默认 Legacy | 两模式端到端对拍、Legacy bit-exact、不增接口错误、板级展开/综合 |
| 5 | 随机背压和误差回归 | 不改变功能定义 | 固定种子矩阵、长测、错误注入、可复现失败信息、全 Gate 回归 |

不能跳过 Gate，也不能同时修改两个 Gate 的数据通路。研究、文档和测试设计可以预先
准备，但只有当前 Gate 的代码可以进入工作分支。

## 3. 为什么采用这个顺序

1. Online Softmax 的 `(m, l)` 状态和舍入规则先成为唯一数值合同，否则 Context
   accumulator 无法判断差异来自 Softmax、累加顺序还是 BF16/FP32 舍入。
2. Context accumulator 是 Streaming 路径的最小计算闭环，先独立验证可把数值问题
   与四 Head 复用、广播和缓存控制问题分开。
3. 四 Head 广播改变的是数据复用和流控，不应与累加器数学正确性同时调试。
4. 双模式最后接板级主路径，Legacy 保持默认，出现问题时可以一键回退并继续上板。
5. 随机背压放在接口和模式稳定后，固定种子必须能复现，不能用随机测试掩盖功能缺口。

## 4. 每个成熟提交的统一验收

每个 Gate 只有同时满足下列条件才允许提交：

- 工作树中没有 Vivado/XSim 生成物；
- 新增测试能在全新克隆中运行，路径不依赖个人目录；
- 当前 Gate 新测试全部 PASS；
- 之前所有 Gate 全部回归 PASS；
- Legacy 默认模式仍能完成板级顶层 RTL elaboration；
- 涉及新 RTL 时完成目标器件 OOC synthesis，并保存机器可读摘要；
- 文档明确 Vivado 版本、参数、随机种子和命令入口；
- 结果中区分 `SIM_PASS`、`SYNTH_PASS`、`BOARD_PASS`，不得把前两者写成上板通过。

提交粒度固定为“一 Gate 一组可回退提交”。推荐提交标题：

```text
test(rtl-gate0): freeze reproducible legacy closure
feat(rtl-gate1): add bit-accurate online-softmax golden
feat(rtl-gate2): add streaming context accumulator
feat(rtl-gate3): add four-head KV tile broadcast
feat(rtl-gate4): integrate legacy/streaming dual mode
test(rtl-gate5): add deterministic backpressure and fault regression
```

只有完整 Gate 提交允许推送。调试快照、仅在本机通过的中间代码和生成工程不推送。

## 5. 当前无板时的闭环定义

```text
算法合同 PASS
      ↓
单元/端到端仿真 PASS
      ↓
XCZU15EG RTL elaboration / OOC synthesis PASS
      ↓
形成可复现提交
      ↓
队友实体板回归（后补 BOARD_PASS）
```

当前开发者可以关闭前三层并形成成熟候选提交；实体板层由拿到
RK-XCZU15EG-F 的队友执行。若板测失败，则在同一 Gate 修复并重新跑完整回归，
不能带着未关闭问题进入下一 Gate。
