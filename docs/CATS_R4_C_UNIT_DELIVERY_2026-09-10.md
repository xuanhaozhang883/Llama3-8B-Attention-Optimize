# CATS-R4 C 单元交付证据（2026-09-10）

状态：`IN PROGRESS / NOT READY FOR C2 INTEGRATION`。

## 1. 本轮交付

本轮完成并验证了以下独立 C 能力：

- IF_V3 三槽 weight memory service：128 keys、mask/data 原子存储、row commit、PV backpressure-stable、N+2 scalar read、outstanding drain 后 release；
- 多槽 READY 仲裁修复：同周期 READY 不再被循环中的多次非阻塞赋值吞掉；
- 同周期多接口错误计数改为聚合累加；
- output CDC 从 80 行抽样扩展为完整 4096 行；
- async FIFO payload RAM 从寄存器展开修复为真实双时钟 BRAM 推断；
- 三时钟 abort/drain controller：隔离新事务、等待 core/AXI outstanding 清零、双域 clear、epoch++、完成握手和硬复位取消。
- 系统计数闭合 gate：在 owner-domain snapshot 已经稳定的前提下，统一校验 `rd_beats=196608`、`wr_beats=131072`、`rows_committed=4096`，并拒绝任一 protocol/conflict/underflow/overflow/seq/epoch/BRESP/RRESP 错误计数非零；含正常、计数不匹配、错误计数和清零回归。

## 2. 可复现命令和结果

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_cats_r4_c_unit_checks.ps1 `
  -OutputRoot C:\Users\Lenovo\AppData\Local\Temp\c4unit_final_20260910

powershell -ExecutionPolicy Bypass -File tests/run_cats_r4_c_vivado_checks.ps1 `
  -VivadoRoot D:\Vitis\2025.2\Vivado `
  -OutputRoot C:\Users\Lenovo\AppData\Local\Temp\c4vg_final_b71d1a97e15a46688589f70b3baeadba
```

结果：

| 门禁 | 结果 |
|---|---|
| Icarus unit | 16 cases PASS（含系统计数闭合 gate 的正常/负向/清零回归） |
| bridge protocol + real XPM XSim | PASS，Q/K/V read latency 12 ns，即 core N+2 |
| IF_V3 weight XSim | PASS，4096 rows / 524288 writes / 524288 reads |
| bridge OOC | WNS +3.372 ns，check_timing 0，methodology 0 |
| Q-slab DMA OOC | WNS +3.420 ns，check_timing 0，methodology 0 |
| weight-slot OOC | WNS +3.205 ns，30×RAM64M8，check_timing 0，methodology 0 |
| output CDC OOC | WNS +3.629 ns，3×RAMB36，check_timing 0，methodology 0，无 Critical CDC |
| abort/drain OOC | WNS +4.941 ns，check_timing 0，methodology 0，8×CDC-3 Info，无 Critical CDC |
| system counter closure OOC | WNS +3.417 ns，check_timing 0，methodology 0，241,256-byte checkpoint；已设置 HD.CLK_SRC |

Vivado 统一脚本会拒绝缺报告、负时序、非零 check_timing、非零 methodology 或 Critical CDC。output CDC 的 4 条 CDC-6 和其余 Gray 指针 warning 属于 ASYNC_REG 保护的多位 Gray 总线，必须在系统集成时复核，不能写成“CDC 全部零 warning”。

## 3. 证据边界

本交付证明的是 C 局部协议、存储、CDC 和 OOC 质量，不证明 C2 READY。系统计数闭合 gate 当前只消费测试中构造的稳定 owner-domain snapshot，并未接入真实系统计数源。尚缺：A/B wrapper 接入、生产 reset/AXI outstanding 接入、真实全局 DDR/counter closure、integrated output writer、整板 implementation/board measurement。`scripts/source_manifest.tcl` 本轮保持不变。

## 4. 代码身份

- 已有代码提交：`0c69bcf feat(c): add v3 weight memory service and Vivado gates`；
- 本轮第二批提交为 `f807b93cd2a877001005c37bdd35cb25dc6afbe2`，包含 async FIFO、4096-row output CDC、abort/drain controller、对应 TB、OOC Tcl 和统一 runner；
- 系统计数闭合 gate 提交为 `3fe71cff64fb9d2fd0d9b7e2f4f1b3a6265844f4`；用户现有 `artifacts/raw_logs/`、未跟踪状态文档没有加入提交。
