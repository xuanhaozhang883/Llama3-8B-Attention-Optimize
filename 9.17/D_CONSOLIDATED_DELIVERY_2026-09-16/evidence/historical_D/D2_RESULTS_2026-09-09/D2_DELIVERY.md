# D2 DELIVERY

- 日期：2026-09-09
- 阶段：D2
- 状态：READY（validation contract/tooling only）
- branch：`codex/d-validation-v3`
- base/head：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
- interface：`CATS_R4_INTERFACE_V3_COMMIT` / `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
- 阈值：`abs<=1e-4 OR BF16 ordered ULP<=1`
- 软件与身份验证：RUN
- 新 RTL/XSim/OOC/full-board/board：NOT RUN

## 已交付

- `D2_VALIDATION_SUMMARY.json`：机器可读总门禁。
- `D2_VALIDATION_REPORT.md`：完整结论和数值解释。
- `D2_INPUT_HASH_MANIFEST.json`：D1、接口、历史原件和 8 个输入身份。
- `D2_TEST_MATRIX.json`、`D2_SEED_MANIFEST.json`：固定测试与 seed。
- `D2_COUNTER_SCHEMA.json`、`D2_ARTIFACT_SCHEMA.json`：后续候选统一口径。
- `D2_INDEPENDENT_REFERENCE_SELFTEST.json`：FP64 与 Decimal(80) 独立交叉检查。
- `D2_PROTOCOL_CHECKER_SELFTEST.json`：合法流程与错误注入自测。
- `D2_WORKLOAD_CONTRACT.json`：full workload 固定计数。
- full、stress、seed 12794 重跑 JSON 以及每条命令原始日志。

## 结果摘要

- full-GQA：524,288 outputs，combined_failures=0，非 bit-exact。
- 独立参考：522 outputs，combined_failures=0。
- 历史 stress：online_q15=482、row_q15=459、software FP32 exp=0。
- 当前 fused stress：fused-vs-math=136、fused-vs-v30=567。
- seed 12794：fused-vs-math=10、fused-vs-v30=13、v30-vs-math=23，已成功复现并保留。

## 下一依赖

B 提交 B2/B3 完整源码、TB、日志、branch 和 commit；A/C 提交 compute-cluster/single-board READY 候选。收到后进入 D3，不能把本 D2 软件 READY 写成硬件 READY。
