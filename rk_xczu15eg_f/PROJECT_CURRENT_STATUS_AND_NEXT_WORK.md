# RK-XCZU15EG-F 项目当前状态与后续工作

更新时间：2026-07-26

## 当前结论

阶段 0 和阶段 1 已完成到“可在 Vivado GUI 中检查并可下载到板卡”的程度：

- 已建立独立、可回溯的 RK worktree；
- 已完成 RK-XCZU15EG-F V1.0、单 GQA、PL-only 工程；
- 行为仿真、综合、布局布线、时序收敛、DRC 和 bitstream 均已实际执行；
- `.bit/.ltx` 已生成；
- 实体板尚未连接，因此不能宣称已经上板跑通。

本轮按约束在阶段 1 停止。没有接入 PS、DDR、MIG、DMA、Linux、SD
卡启动或 8 GQA。

## 仓库与版本状态

| 项目 | 状态 |
|---|---|
| 原工作区 | `<original_repo_root>` |
| 原分支/HEAD | `kv260-attention-bringup` / `5520fb4` |
| 原工作区状态 | 原有大量修改，保持不动 |
| RK 独立 worktree | `<repo_root>` |
| RK 分支 | `rk-xczu15eg-pl-selftest` |
| 基线 | `origin/main` 的 `5e2ff7b` |
| 迁移的 KV260 自检提交 | `ccb41e4`（来自 `5520fb4`） |
| Stage 0 提交 | `40fc01e` |
| Stage 1 RTL/仿真提交 | `d569f8c` |
| Stage 1 实现/bitstream 源提交 | `5a128c8` |

## 已执行并验证

### 板级与工程

- 目标器件：`xczu15eg-ffvb1156-2-i`
- Vivado：2025.2
- 差分时钟：`PL_CLK0_P/N`
- P/N 管脚：AL8 / AL7，Bank 64
- 器件数据库分类：两者均为 `GC` 管脚，`IS_GLOBAL_CLK=1`
- 外部时钟：200 MHz
- Attention 时钟：Clocking Wizard 输出 100 MHz
- XPR：
  `<repo_root>\rk_xczu15eg_f\vx\rk_pl_selftest.xpr`

`vx` 是有意采用的短目录。更长路径会触发 Vivado Chipscope
debug-hub 临时路径超过 146 字符的错误。

### 数据通路

实际运行生产数据通路：

```text
Q/K -> RoPE -> QK -> Scale/Mask -> Softmax -> PV -> Context compare
```

配置为一个 GQA 组：4 个 Q Head，共享 1 个 K/V Head；`SEQ_LEN=128`，
`HEAD_DIM=128`。Q/K/V 和 expected Context 均来自片上初始化存储。

### 行为仿真

| 指标 | 结果 |
|---|---:|
| 完整运行次数 | 2（含 restart） |
| 每次 Context 比较数 | 65,536 |
| 每次 Q/K 请求数 | 40,960 |
| mismatch | 0 |
| first_error_index | 131,071（无错误哨兵） |
| cycle_count | 16,170,681 |
| 100 MHz 对应生产运行时间 | 161.70681 ms |

该时间不含最初 V-cache 加载，也不含未来主机、DDR 或 DMA 传输，
因此不是 host-to-host 端到端延迟。

### 综合、实现与 bitstream

| 指标 | 结果 |
|---|---:|
| CLB LUT | 68,231 / 341,280（19.99%） |
| CLB Register | 35,129 / 682,560（5.15%） |
| BRAM Tile | 89.5 / 744（12.03%） |
| URAM | 0 / 112 |
| DSP48E2 | 136 / 3,528（3.85%） |
| WNS | +2.221 ns |
| WHS | +0.011 ns |
| Routing error nets | 0 |
| Bitstream DRC error | 0 |
| 功耗估算 | 1.127 W，vectorless、Medium confidence |

所有 `check_timing` 类别均为 0，未发现无时钟寄存器或未约束内部端点。
CDC 的 4 条 warning 全在 Vivado 生成的 debug hub 内，且带厂商
false-path 约束；生产 Attention 时钟域未发现严重 CDC。

## 已生成但尚未实体验证

```text
rk_xczu15eg_f/artifacts/rk_xczu15eg_f_pl_selftest.bit
rk_xczu15eg_f/artifacts/rk_xczu15eg_f_pl_selftest.ltx
```

两者必须成对使用。实体板验证状态：

```text
HARDWARE VALIDATION PENDING
```

## 当前唯一阻塞项

需要人工提供并操作 RK-XCZU15EG-F V1.0 实体板、电源、散热和 JTAG。
工具、器件、IP、实现许可、时序、DRC 与 bitstream 生成均已通过。

厂商用户 Tcl Store 的个人目录有损坏提示，但本工程只使用内置 AMD
IP，实际构建未受阻；没有自动重置用户的 Tcl Store。

## 下一步：只做实体板验收

1. 打开上述 XPR。
2. 进入 Hardware Manager 并 Auto Connect。
3. 用匹配的 `.bit/.ltx` Program Device。
4. 在 VIO 等待 `done=1`。
5. 确认 `pass=1`、`fail=0`、`error_count=0`、
   `first_error_index=131071`。
6. 记录 `cycle_count`。
7. 用 `restart` 进行至少 100 次连续回归。
8. 保存 VIO/ILA 截图并补全硬件验证报告。

完整 GUI 操作见
`rk_xczu15eg_f/docs/HARDWARE_MANAGER_VIO_GUIDE.md`。

## 人工确认后才可启动的阶段 2

后续建议按串行门禁推进：

1. 先完成实体板单 GQA 验收；
2. 再独立设计 PS/AXI 控制与 DMA 数据搬运；
3. 再决定 PS DDR 或 PL DDR/MIG 方案，并使用厂商 master XDC/preset；
4. 建立 host-to-host 端到端延迟测量；
5. 最后从单 GQA 扩展到多 GQA，逐步做 KV reuse、调度和资源优化。

本轮未执行以上阶段 2 工作。
