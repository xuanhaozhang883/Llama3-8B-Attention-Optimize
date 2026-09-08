# 队长状态摘要

当前发布基线：`CATS_R4_INTERFACE_V3_COMMIT`，工作分支最新提交由 GitHub 远端确认。

## 已交付

- v3 Accuracy FP32 weight 开发接口冻结。
- 两份 `row_candidates_*.json` 原件恢复、哈希和结构校验。
- 团队规则、交付模板、发布门禁、150 MHz 构建规则。
- C bridge 接口差异矩阵及审计补充。

## 当前门禁

| 项目 | 状态 | 队长动作 |
|---|---|---|
| 资料归档 | READY | 保持原始哈希，不改历史结果 |
| 接口冻结 | READY for unit development | 成员必须回报消费 tag |
| A | NOT READY | 等 score/ownership/counter 证据 |
| B | NOT READY | 收 B2 源码 SHA，补 Accuracy 数值实现 |
| C bridge | NOT READY | 完成真实 XPM、owner、短尾和 reset 证据 |
| C 上层 DMA/CDC/output | NOT READY | 追踪候选模块并做集成回归 |
| 整板 C2 | BLOCKED AT ENTRY GATE | 不生成 BIT/XSA/ELF |

## 队长下一次只接受的交付

每份交付必须复制 `CATS_R4_DELIVERY_TEMPLATE.md`，填写 branch、base/head SHA、接口 tag、
工具版本、测试命令、输入/日志哈希、counter 和下一依赖。没有源码 SHA 的截图只记为报告，
不改变门禁状态。

收到可审查 B2 后，队长按顺序：保存身份 → 端口差异 → 复现测试 → C 集中工具验证 → 更新门禁。
只有所有单元 READY 后才进入 150 MHz C2；200 MHz 和 2/4 cluster 必须另行提交。
