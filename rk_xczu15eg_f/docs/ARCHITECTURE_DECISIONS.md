# Architecture Decisions

本文件记录影响可复现性、板级安全、测量边界和比赛主线的已决事项。修改已接受
决策时必须新增 superseding decision，不能静默改写历史结论。

## ADR-001：冻结 Stage 1，建立最终系统分支

- 状态：Accepted
- 决策：保留 `rk-xczu15eg-pl-selftest` @ `83073ae` 作为 Stage 1
  回归基线；后续工作在 `rk-xczu15eg-final-system` 进行。
- 原因：隔离已验证 PL-only 设计与后续 PS/DDR/DMA 系统改动。
- 后果：任何 Stage 1 回归都应能与冻结提交和匹配 bit/LTX 比较。

## ADR-002：Stage 1 使用双证据状态

- 状态：Accepted
- 决策：Stage 1 软件为 `SOFTWARE_PASS`，硬件门为
  `HARDWARE_PENDING`，阶段整体不得写成 `HARDWARE_PASS`。
- 原因：Vivado 仿真/实现/bitstream 已通过，但本环境没有实体板运行证据。
- 后果：实现报告不能替代 100 次 restart、重新下载和冷启动结果。

## ADR-003：`first_error_index` 的无错误哨兵为 17 位全 1

- 状态：Accepted
- 定义：`NO_ERROR_INDEX = 17'h1ffff = 131071`。
- RTL 行为：reset/restart 时赋哨兵；只有首次 mismatch 时写实际
  `compared_count`。
- 合法范围：当前 65,536 个 Context 元素的下标为 `0..65535`，与哨兵不冲突。
- 验证：RTL、testbench、仿真 Tcl 和两次仿真结果一致。
- 后果：VIO 看到 `error_count=0` 且 `first_error_index=131071` 是预期 PASS
  条件；不需要修改状态寄存器。

## ADR-004：Vivado GUI 工程使用短生成路径

- 状态：Accepted
- 决策：GUI 入口保持
  `rk_xczu15eg_f/vx/rk_pl_selftest.xpr`。
- 原因：更长 Windows 路径会让 Vivado Chipscope debug-hub 临时路径超过
  146 字符。
- 后果：`vx/` 是可删除/重建的本机工程，不作为源交付；Tcl 是权威工程定义。

## ADR-005：bit/LTX 不进入普通 Git 提交

- 状态：Accepted
- 决策：大型制品放 `artifacts/`，由 manifest 与 SHA-256 管理，默认通过
  GitHub Release、Git LFS 或受控制品库分发。
- 原因：避免仓库膨胀和错误的 bit/LTX 配对。
- 后果：上板必须同时核对 source/build commit、board、Vivado 版本和两份 hash。

## ADR-006：板级 DDR/PS 配置不得从 PDF 或相似板卡猜测

- 状态：Accepted
- 决策：Stage 2 必须优先使用厂商 V1.0 Master XDC、MIG XCI/Tcl 和
  reference；Stage 3 必须优先使用厂商 PS preset/reference。
- 原因：实际 DDR 为 `MT40A512M16LY-062E`，教程示例使用不同
  `MT40A512M16HA-083E`；错误 DDR/PS 参数会造成校准、数据或电气风险。
- 后果：当前 Stage 2/3 标为 `BLOCKED`；只允许做不生成猜测 bitstream 的准备。

## ADR-007：Stage 2 与 Stage 3 独立 bring-up

- 状态：Accepted
- 决策：PL DDR memory test 和 PS/PS DDR minimal system 使用独立最小工程，
  各自 hardware pass 后再接主系统。
- 原因：避免同时调试 DDR、PS、DMA 和 Attention。
- 后果：两条准备工作可并行；Stage 4 只依赖 Stage 3，Stage 2 是否进入最终数据
  路径由 profiling 决定。

## ADR-008：最短 baseline 优先使用 PS DDR + AXI DMA

- 状态：Accepted
- 决策：第一版 host-to-host 使用 PS DDR、AXI DMA simple mode、AXI4-Stream
  Attention 和 PS DDR 回写。
- 原因：通用 IP 可最快建立真实数据闭环，且不会被可选 PL DDR 阻塞。
- 后果：先完成 loopback 和单 GQA，再扩 8 GQA；profiling 后才替换真正瓶颈。

## ADR-009：bare-metal 是性能 baseline 的首选软件环境

- 状态：Accepted
- 决策：先用 bare-metal 建立 UART、PS DDR、DMA 和性能测量；Linux 是文件管理
  与演示增强，不得阻塞 baseline。
- 原因：启动快、调度噪声小、cache/DMA 边界易控制。
- 后果：最终结果必须标明软件环境；Linux 与 bare-metal 数据不可混为同一测量。

## ADR-010：保留 ROM self-test，另建 production wrapper

- 状态：Accepted
- 决策：Stage 5 不删除现有 PL-only ROM 自检，新增 AXI4-Stream/AXI-Lite
  production wrapper。
- 原因：ROM 自检是稳定的计算回归；production wrapper 验证真实数据路径。
- 后果：production PPA 必须排除 ROM、比较器、VIO/ILA 调试资源。

## ADR-011：固定三层延迟定义

- 状态：Accepted
- Kernel latency：命令接受到最后一个 output handshake。
- Transaction latency：第一次输入 DMA 发起到输出 DMA 完成。
- Application latency：软件准备、cache、DMA、kernel、读回和比较。
- 后果：Stage 1 的 161.70681 ms 只是 production-run kernel proxy，不含初始
  V-cache 加载与主机/DMA，不能宣称 host-to-host。

## ADR-012：先冻结 `BASELINE_A0`，再做单变量优化

- 状态：Accepted
- 决策：Stage 6 正确后由 Stage 7 冻结完整 8 GQA baseline；Stage 8 才按
  A1–A7 单变量实施 tiled、fused online、GQA reuse、DMA overlap、causal skip、
  cluster 和频率扫描。
- 原因：没有同输入、同边界 baseline 就无法证明创新贡献。
- 后果：不得把多个结构优化混入同一验收提交；INT8/稀疏属于 BF16 baseline 后
  的可选增强。

## ADR-013：最终主创新为 GQA-aware exact streaming attention

- 状态：Proposed，待 Stage 7 profiling 后锁定参数。
- 结构：Tiled QK → Scale → Causal Mask → Online Softmax →
  Streaming PV → Context accumulator。
- 核心要求：不落完整 Score/P；K/V tile 在同组 4 个 Q heads 复用；
  `m/l/O` 状态隔离；DMA/计算重叠；causal tile skip。
- 后果：创新必须通过 latency、DDR bytes、bandwidth、PPA、power、correctness
  和消融数据证明，不能只凭架构图宣称。
