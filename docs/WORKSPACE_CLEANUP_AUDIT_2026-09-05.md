# 03_work_v314_causal_bypass 文件清理审计

审计日期：2026-09-05  
审计范围：仅本目录，不包括 `D:\Vitis\FPT\tmp`、`SOURCE_ARCHIVE_20260902`、论文或其他工程。

## 结论

本工作区已经较精简：除 `.git` 外约 24.7 MiB，其中约 18.0 MiB 是板测源码和固定 Q/K/V/golden
数据，约 3.9 MiB 是当前匹配 XSA，约 1.5 MiB 是实现报告。这些都不是无意义重复。

当前可以安全删除的只有三类可重建/重复文件，合计约 143 KiB：

| 处理 | 精确路径 | 原因 |
|---|---|---|
| 删除 | `.Xil/` | 仅含一个 0 字节临时 XDC；Vivado 可重建 |
| 删除 | `python/__pycache__/` | Python 字节码缓存；可重建 |
| 删除 | `dfx_runtime.txt` | 本机运行时临时文件；已被 `.gitignore` 忽略 |
| 删除 | 根目录 `cos_bf16.hex` | 与受 Git 管理的 `mem/cos_bf16.hex` SHA-256 完全相同 |
| 删除 | 根目录 `sin_bf16.hex` | 与受 Git 管理的 `mem/sin_bf16.hex` SHA-256 完全相同 |
| 删除 | 根目录 `exp_lut_q15.mem` | 与受 Git 管理的 `mem/exp_lut_q15.mem` SHA-256 完全相同 |

三个生产 ROM 的唯一保留位置应为 `mem/`。生产 `source_manifest.tcl`、OOC Tcl 和 RTL 构建入口均从
`mem/` 加载它们；根目录副本是构建过程留下的临时副本，并已被 `.gitignore` 明确忽略。

## 精确重复证据

| 重复文件 | 保留文件 | SHA-256 |
|---|---|---|
| `cos_bf16.hex` | `mem/cos_bf16.hex` | `D30190CD0886513845147A77BAAC3A3453598A617E86F580F1AB25234DB5BD3D` |
| `sin_bf16.hex` | `mem/sin_bf16.hex` | `C98A462FA05FC69845ACBE8B6175A1EC854AC91E1FB5B4A33E2AA7F84271FC5D` |
| `exp_lut_q15.mem` | `mem/exp_lut_q15.mem` | `27DF1F7633E03E2693164FA8997452118A2AB7B367BFA86618C9E0605E2D317D` |

对 `.git` 之外的全部 141 个文件做 SHA-256 分组后，只发现以上 3 组完全相同的文件。

## 不得删除

以下内容即使被 `.gitignore` 忽略，也必须保留：

- `export/fpt_attention_board_v314_qk4_causal_bypass.xsa`：当前 P2C 匹配、含 bit 的 XSA；
- `reports/drc_impl.rpt`、`power_impl.rpt`、`timing_summary_impl.rpt`、`utilization_impl.rpt`：
  当前 v3.1.4 full-board 实现证据；
- `artifacts/P2C_ARTIFACT_MANIFEST_2026-09-04.json`：BIT/XSA/ELF 身份链；
- `reports/ppa_summary.*`、`reports/host_full_gqa_numerical_20260902.json`：PPA 与数值摘要；
- `vitis/data/*.hex` 和 `vitis/src/fpt_golden_vectors.h`：板测输入、golden 和裸机编译所需内容；
- `mem/*`：生产 ROM；
- `bd_base/`、`rtl/`、`tb/`、`tests/`、`scripts/`、`python/`：生产源码与验证入口；
- `.git/`：当前分支和提交历史；
- 当前未提交的 `docs/BOARD_BRINGUP_TUTORIAL_V314.md`、`docs/STEP_BY_STEP_PROMPTS_CN.md` 和
  `docs/TEAM_4_COLLABORATION_PLAN.md`：均为正在进行的用户工作，不能清理。

特别注意：不能在本目录直接运行不加选择的 `git clean -fdX`。它不仅会清缓存，还会同时删除被
忽略但必须保留的 XSA 和实现报告。

## 后续审计与删除流程

真正删除前按以下顺序执行：

1. 确认 Vivado、Vitis、XSCT、仿真器和使用该工作区的终端均已退出。
2. 重新运行 `git status --short`，确认三份当前文档修改已提交或明确归属，绝不处理未提交源码。
3. 重新计算根目录 ROM 与 `mem/` ROM 的 SHA-256；只有三组仍完全相同时才删除根目录副本。
4. 只删除上表列出的六个精确目标，不使用通配符，不运行全目录 `git clean`。
5. 删除后运行生产 manifest 检查、Host/RTL 快速回归和 `git status --ignored --short`。
6. 验证 XSA、四份实现报告和 artifact manifest 仍存在且哈希未变。
7. 在本文件追加清理时间、执行人、删除目标、清理前后大小和验证结果。

## 将来构建后的规则

- `.Xil/`、`python/__pycache__/`、根目录 ROM 副本和 `dfx_runtime.txt` 可在每次工具退出后清理；
- 新的 Vivado/Vitis 大型 build root 应放在工作区外的短 ASCII 临时路径，不纳入本目录；
- 每个正式候选只把必要报告摘要、artifact manifest 和经哈希确认的发布产物进入归档；
- 未归档、仍被 manifest 或板测教程引用的 BIT/XSA/ELF 不能删除；
- 任何同名文件只有 SHA-256 相同才能按“重复”删除，不能仅凭文件名或大小判断。

## 本次状态

本次只完成只读审计并生成本报告，没有删除任何文件。
