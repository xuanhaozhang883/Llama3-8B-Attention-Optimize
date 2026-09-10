# D 给 A/B/C/队长的交付索引

日期：2026-09-10

请直接发送整个 `D/output` 文件夹，不要只发送截图。

## 必看文件

1. `CATS_R4_NEXT_WORK_PLAN_2026-09-09_D_STATUS_UPDATED.md`
   - D1/D2/D3 当前状态和下一入口。
   - 2026-09-10 补充内容优先于前文旧状态。

2. `D2_VALIDATION_TELEMETRY_2026-09-09/D2_VALIDATION_TELEMETRY_CONTRACT_2026-09-09.md`
   - B/C 后续实现必须满足的数值、counter、telemetry、artifact 契约。

3. `D2_VALIDATION_TELEMETRY_2026-09-09/D2_RESULTS_2026-09-09/D2_VALIDATION_REPORT.md`
   - D2 独立验证结果与限制。

4. `D3_PRE_ABLATION_V313_V314_2026-09-10/D3_PRE_ABLATION_REPORT_2026-09-10.md`
   - 已完成的 v3.1.3 → v3.1.4 causal-bypass 消融。
   - CATS-R4 正式 row/online D3 的入口审计。

5. `D_OUTPUT_SHA256_MANIFEST_2026-09-10.json`
   - output 内全部交付文件的 SHA-256；manifest 自身不包含在清单内。

## 当前结论

- D1：READY，v3.1.4 fallback 板测签核通过。
- D2：READY，仅限独立验证与 telemetry 契约/工具。
- 前置消融：`PASS_WITH_LIMITATIONS`；v3.1.4 相对 v3.1.3 周期降低
  `28.588761%`，加速 `1.40034x`。
- CATS-R4 A2：A 自报 unit/OOC READY，仍需 D 独立审计 candidate golden。
- CATS-R4 正式 row/online D3：`BLOCKED_AT_ENTRY_GATE`。

正式 D3 仍缺 B2 READY SHA、B3 READY SHA、A3 single-cluster wrapper SHA、
C memory-service integration SHA，以及两套同输入、精度、lanes、频率和计时边界的
row/online runner 与证据。

## 文件纪律

- `logs`、JSON、原始 UART 和 manifest 都是证据，不要修改后再转发。
- `combined_failures=0` 表示误差门禁通过，不表示 bit-exact。
- 软件、RTL 仿真、OOC、full-board、板测证据等级不可互相替代。
