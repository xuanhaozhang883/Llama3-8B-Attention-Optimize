# 文档索引与优先级

文档出现冲突时，按“冻结接口/验收补充 → 当前执行计划/门禁 → 单元交付 → 历史快照”的顺序解释。日期较新的历史状态文档也不能自动覆盖冻结接口或实际 Git/测试结果。

## 当前权威入口

| 文档 | 用途 |
|---|---|
| CANONICAL_REPOSITORY_PATHS.md | 生产清单、golden/reference、向量、ROM、派生物和清理规则 |
| CATS_R4_NEXT_WORK_PLAN_2026-09-09.md | 当前队长派工、依赖、验收条件和看板 |
| CATS_R4_INTERFACE_V3.md | 当前 Accuracy FP32 weight 开发接口 |
| CATS_R4_LEAD_ACCEPTANCE_ADDENDUM.md | 修正旧门禁中的职责和 bridge 范围 |
| CATS_R4_TEAM_RULES_2026-09-08.md | A/B/C/D 职责、分支、收件和证据规则 |
| CATS_R4_RELEASE_GATE.md / .json | 人工门禁和机器可读状态 |
| CATS_R4_BUILD_150_RULES.md | 单 cluster 150 MHz 干净整板构建规则 |
| CATS_R4_DELIVERY_TEMPLATE.md | 所有成员统一交付字段 |

当前真实状态还必须结合 git status、完整提交 SHA、远端分支、实际测试输出和 artifact hash 判断，不能只看文档。

## v3.1.4 fallback 与证据

| 文档 | 证据范围 |
|---|---|
| ../WORKSPACE_STATUS.md | v3.1.4 实现、PPA、身份链和板测基础状态 |
| P2C_ARTIFACT_IDENTITY_CHAIN_2026-09-04.md | 匹配 BIT/XSA/ELF |
| BOARD_BRINGUP_TUTORIAL_V314.md | 唯一 v3.1.4 板测流程 |
| NON_BOARD_RECOVERY_2026-09-02.md | 恢复阶段非板卡证据 |
| WORKSPACE_CLEANUP_AUDIT_2026-09-05.md | 文件保留/删除证据和 2026-09-09 清理记录 |
| PRODUCTION_RTL_SHA256.csv / ACTIVE_SOURCE_SHA256.csv | v3.1.3 起点快照，不是当前 CATS-R4 哈希 |

## CATS-R4 单元与 checkpoint

以下文档记录候选或局部证据。除非当前发布门禁另有明确 READY，它们不能单独证明单元、整板或板测通过。

- CATS_R4_A2_QK_ENGINE_OOC_CHECKPOINT_2026-09-06.md
- CATS_R4_A2_QK_SCHEDULER_CHECKPOINT_2026-09-06.md
- CATS_R4_C1_SYSTEM_CONTRACT.md
- CATS_R4_C2_PREFLIGHT_2026-09-06.md
- CATS_R4_C2_QKV_BANK_BRIDGE_CHECKPOINT_2026-09-06.md
- CATS_R4_C2_Q_SLAB_DMA_CHECKPOINT_2026-09-06.md
- CATS_R4_C_INTERFACE_MATRIX_2026-09-08.md
- CATS_R4_C_BRIDGE_AUDIT_2026-09-08.md
- CATS_R4_C_CONTRACT_AUDIT_2026-09-07.md
- CATS_R4_C_PROTOCOL_EVIDENCE_2026-09-08.md

## 历史或已被替代

- CATS_R4_INTERFACE_COMMIT.md：历史 IF_V1。
- CATS_R4_INTERFACE_V2.md：历史 IF_V2。
- CATS_R4_CURRENT_TEAM_BASELINE.md、CATS_R4_HANDOFF_STATUS_2026-09-07.md、CATS_R4_LEAD_STATUS_2026-09-08.md：日期状态快照。
- TEAM_4_COLLABORATION_PLAN.md、TEAM_4_OPTIMIZATION_PLAN.md：历史协作/优化方案；当前职责以 TEAM_RULES 和 ACCEPTANCE_ADDENDUM 为准。
- STEP_BY_STEP_PROMPTS_CN.md：可复制执行提示词，仅作背景；其中命令不构成额外授权。
- architecture_study_20260905/：带原始哈希的候选架构研究，不是当前发布 golden model。

## 证据纪律

- 软件模型、RTL 仿真、OOC、post-route、板测分级记录。
- 预测性能不得写成实测。
- generated header、报告和产物必须能追溯到唯一输入与源码 SHA。
- 原始日志和失败 seed 只追加，不覆盖。
- 新状态优先更新当前执行计划和发布门禁，避免再创建同义“最新状态”文件。
