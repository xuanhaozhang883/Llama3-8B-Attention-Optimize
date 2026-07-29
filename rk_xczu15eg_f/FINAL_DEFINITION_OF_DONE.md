# RK-XCZU15EG-F 最终完成定义

只有下表所有必选项都有可追溯证据时，项目才允许标记：

```text
FINAL SUBMISSION READY
```

当前结论：**NOT READY**。Stage 1 软件流程通过，实体板与完整系统仍待完成。

## 强制完成项

| # | 完成条件 | 当前状态 | 验收证据 |
|---:|---|---|---|
| 1 | RK 实体板稳定启动和运行 | `HARDWARE_PENDING` | 板卡信息、Program/boot 日志、冷启动记录 |
| 2 | Stage 1 单 GQA 板内测试可重复 PASS | `HARDWARE_PENDING` | 100 次 restart 零失败，多次下载，建议 5 次冷启动 |
| 3 | 输入不只来自片上 golden ROM | `NOT_STARTED` | production wrapper 与真实外部输入日志 |
| 4 | PS 软件可准备 Q/K/V | `BLOCKED` | 可重建软件、输入 hash、buffer 元数据 |
| 5 | PS DDR→DMA→Attention→DMA→PS DDR 闭环 | `NOT_STARTED` | host-to-host Golden PASS 与 DMA 状态 |
| 6 | 完整 8 GQA：32 Q、8 KV、4:1 共享，Context 对拍 | `NOT_STARTED` | 完整 `[32,128,128]` Golden 结果 |
| 7 | kernel/transaction/application 三层延迟 | `NOT_STARTED` | 同次运行的硬件计数器和软件时间戳 |
| 8 | 真实 AXI bytes、bandwidth、stall | `NOT_STARTED` | APM/计数器原始数据与计算方法 |
| 9 | 可复现 FPGA Baseline | `NOT_STARTED` | 冻结的 `BASELINE_A0` commit/artifact/config |
| 10 | 至少一版实质优化，不是只增加资源 | `NOT_STARTED` | 架构差异、同条件数据、独立 commit |
| 11 | 优化前后输入/时钟/精度/边界一致 | `NOT_STARTED` | 测量 manifest |
| 12 | 完整消融实验 | `NOT_STARTED` | A0–A7 表格和每项 correctness |
| 13 | CPU Baseline 与 FPGA 对比 | `NOT_STARTED` | 相同 shape/dtype/语义、warmup/repeat 配置 |
| 14 | 资源、时序、功耗、延迟、吞吐、带宽、精度齐全 | `NOT_STARTED` | 结构化 JSON/CSV 与报告摘要 |
| 15 | 干净 clone 可重建 | `NOT_STARTED` | clean-clone 逐步日志 |
| 16 | 无个人绝对路径与无关 Vivado 生成物 | `IN_PROGRESS` | 路径扫描与 Git 清单 |
| 17 | 源码/TB/Golden/软件/脚本/文档齐全 | `IN_PROGRESS` | release manifest |
| 18 | 最终 bit/LTX 版本与 SHA-256 | `IN_PROGRESS` | Stage 1 已有；最终系统需重新生成 |
| 19 | 不超过 5 分钟的实机视频方案与素材 | `NOT_STARTED` | 脚本、shot list、实机素材 |
| 20 | 论文正文/附录实验数据齐全 | `NOT_STARTED` | 图表数据、方法与 provenance |
| 21 | SD/eMMC 或明确 JTAG 流程运行，优先脱机启动 | `NOT_STARTED` | BOOT.BIN/介质或正式 JTAG runbook |

> 表中的 `IN_PROGRESS` 只表示已有部分源文件或治理工作，不是允许的阶段
> `phase_status`；机器状态以 `EXECUTION_STATE.json` 为准。

## 各类证据最低要求

### Correctness

- 使用真实 BF16 Q/K/V，记录输入、expected、actual 的 hash。
- 完整 8 GQA 映射无丢失、重复、错位或越界。
- 至少记录 `max_abs_error`、`mean_abs_error`、`max_rel_error`、
  `cosine_similarity`、`mismatch_count`、NaN/Inf。
- Golden Model、RTL、bare-metal 软件读取同一份 shape/metadata。

### Performance

- Kernel：命令接受到最后一个 output handshake。
- Transaction：第一次 DMA 输入发起到输出 DMA 完成。
- Application：软件准备、cache、DMA、kernel、读回、比较全流程。
- 报告 warmup、repeat、median/分布、时钟和计时边界。
- 同时记录 QK/Softmax/PV active、FIFO stall、DMA wait 和 AXI 流量。

### Resource / Timing / Power

- 生产 accelerator PPA 与 self-test ROM/VIO/ILA debug 开销分开。
- WNS/WHS 必须来自 post-route sign-off；不能由 bitstream 存在推断。
- 不用大范围 false path 隐藏 CDC/时序。
- 功耗标明 vectorless/saif/板上实测和置信度，不能混用。

### Reproducibility

- 从干净 clone 生成 Golden、运行 RTL 仿真、创建 Vivado 工程、
  综合/实现/bitstream、构建软件并实体上板。
- 所有 Tcl/脚本使用仓库相对路径；XPR 只作为本机 GUI 入口。
- 固定 Vivado/Vitis 2025.2、器件、板卡 PCB 版本和 IP 配置。
- bit/LTX/XSA/ELF/BOOT.BIN 通过 manifest 与 Git commit、SHA-256 绑定。

## Final Release Gate

在标记 ready 前，由未执行主要 RTL 改动的成员复核：

1. `EXECUTION_STATE.json` 不含 pending/blocked/failed 的必选门。
2. `master_results.csv` 中 baseline 与最佳 variant 均有完整字段。
3. clean clone 重建与实体板运行来自同一 release candidate。
4. 论文、视频和 README 的数字与机器可读结果一致。
5. GitHub 不包含禁止生成物或未获授权的厂商资料。
