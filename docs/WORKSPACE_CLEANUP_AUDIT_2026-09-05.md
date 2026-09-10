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

2026-09-05：只完成只读审计，没有删除文件。

2026-09-09：按精确清单完成第一批整理：

- 从 Git 工作树移除 03_work_v314_causal_bypass.zip（16,642,860 bytes）。该 ZIP 包含整个 .git，是仓库自备份；可从 Git 历史恢复。
- 删除 .Xil/、python/__pycache__/、dfx_runtime.txt。
- 删除根目录 cos_bf16.hex、sin_bf16.hex、exp_lut_q15.mem；生产 mem/ 副本保留。
- Git 跟踪内容由约 37,238,556 bytes 降至约 20,595,696 bytes，减少约 44.7%。
- 新增 tests/check_repository_hygiene.py，验证唯一入口、禁止跟踪项、ROM 唯一性和派生 header。
- 根目录 Vivado 日志随后按第二批规则移入本地忽略归档，未直接删除。

清理后检查全部 PASS：

- python tests/check_repository_hygiene.py
- python tests/check_cats_r4_lead_release.py
- python tests/test_cats_r4_v3_capacity.py
- python tests/check_cats_r4_gate_manifest.py
- tests/run_v31_flash_numerical_model.ps1（90 rows / 11,520 elements，combined_failures=0）
- git diff --check

受保护证据仍存在；关键身份未改变：

- XSA SHA-256：DD878BF6AC48D33F61BD7E504B550B29B869476253AD7DB6325F793A8E86A2EB
- artifacts/P2C_ARTIFACT_MANIFEST_2026-09-04.json SHA-256：8A7F65B337086961EE27FBF0E65C7FFD8CD93F9267BE4BF343D7410AF6B167E3

## 远端分支审计（2026-09-09）

本轮未删除远端分支。建议保留：

- origin/main；
- origin/codex/cats-r4-local-integration；
- origin/agent/cats-r4-a2-row-handoff；
- origin/codex/cats-r4-c2-single-cluster，至少保留到 C2 checkpoint 被当前门禁吸收或明确废弃。

以下分支已显示 merged into origin/main，可作为后续远端清理候选；删除前仍需队长确认没有未迁移的交付/PR/外部引用：

- origin/agent/online-softmax-context-v3
- origin/backup/origin_main
- origin/codex/flashattention-stage1-fifo
- origin/flashattention-prep-xuanhao
- origin/flashattention-profile-xuanhao
- origin/restore-project-20260730
- origin/rk-xczu15eg-final-system-delivery
- origin/leo/attention-mask-module
- origin/leo/cpu-baseline

origin/agent/rope-qk-integration 与 origin/rope-qk-integration 均指向 f264c0c，是明确的同 SHA 重复分支候选。远端分支属于协作入口，未经明确批准不执行 git push --delete。

## 第二批本地整理（2026-09-09 至 2026-09-10）

第二批只移动经核验的重复文档和根目录工具日志，不删除任何源码、冻结向量、构建产物或原始板测证据。目标统一放入被 `.gitignore` 忽略的 `artifacts/local_archive/`；该目录只用于本机临时留档，不是发布证据入口。

精确重复文档：

| 本地归档文件 | 仓库内保留文件 | SHA-256 |
|---|---|---|
| `artifacts/local_archive/2026-09-09/duplicate_docs/CATS_R4_A2_QK_SCHEDULER_CHECKPOINT_2026-09-06 - 副本.md` | `docs/CATS_R4_A2_QK_SCHEDULER_CHECKPOINT_2026-09-06.md` | `F89527AC4D86EFB405BA0C88E5E0B1A639E3CC0394CCEB7B34FB38FD80F9919A` |
| `artifacts/local_archive/2026-09-09/duplicate_docs/CATS_R4_A_B_STATUS_AND_B2_DECISIONS_2026-09-09 - 副本.md` | `docs/CATS_R4_A_B_STATUS_AND_B2_DECISIONS_2026-09-09.md` | `EEF2733AA954BFCBF6525B21932F16EA54DA8D0DE9BA3E9BF5B17E2E41F5DEDB` |

根目录 `vivado*.log`、`vivado*.jou` 按精确文件名移入：

- `artifacts/local_archive/2026-09-09/vivado_root_logs/`：整理前已有的 4 个日志/日志备份；
- `artifacts/local_archive/2026-09-10/vivado_root_logs_after_c_gate/`：本轮 C 门禁在根目录重新生成的 10 个日志/日志备份。

移动前逐文件计算 SHA-256；本地归档保留原文件名。正式 OOC/XSim 输出改到系统临时目录的独立 case root，避免继续污染仓库根目录。用户现有 `artifacts/raw_logs/`、未跟踪文档、XSA、实现报告和 frozen vectors 均未移动、删除或捎带提交。
