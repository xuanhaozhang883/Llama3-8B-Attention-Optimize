# 证据文件说明

- `PRODUCTION_RTL_SHA256.csv` 和 `ACTIVE_SOURCE_SHA256.csv` 是 `workspace-v313-gate0` 时捕获的 v3.1.3 身份快照，用于证明活动分支的起点；它们不是 v3.1.4 当前文件哈希。
- v3.1.4 及后续版本以 Git 提交、匹配 BIT/XSA/ELF 的 SHA-256 和原始 UART 日志组成身份链。
- `NON_BOARD_RECOVERY_2026-09-02.md` 记录当前可重复证据与阻塞；`TEAM_4_OPTIMIZATION_PLAN.md` 记录人员边界和合并 Gate。
- `STEP_BY_STEP_PROMPTS_CN.md` 提供可逐条复制的主线 Gate、四人分工、验收、恢复和失败诊断提示词。
