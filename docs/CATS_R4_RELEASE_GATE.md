# CATS-R4 发布门禁

基线：`CATS_R4_INTERFACE_V3_COMMIT`。每个勾选项必须附完整 commit SHA、命令和日志路径。

## 资料和接口

- [x] 两份 row-candidate JSON 已恢复并通过哈希/结构校验。
- [x] Accuracy FP32 weight v3 接口已冻结。
- [ ] A/B/C 均确认消费同一个接口 tag。
- [ ] 所有交付包含源码、TB、脚本、工具版本、输入和日志哈希。

## A 单元

- [ ] Q/K scheduler、score/max、FP32 weight formatter 单测通过。
- [ ] score、weight、row-commit ownership 与 v3 token 完全匹配。
- [ ] full workload counter 和失败用例日志已提交。
- [ ] A 单元/OOC READY。

## B 单元

- [ ] B2 源码已进入可审查远端分支。
- [ ] Compatibility exp/sum/reciprocal/PV 通过。
- [ ] Accuracy FP32 exp/sum/reciprocal/PV 已实现并通过。
- [ ] mask、非有限值、下溢、reciprocal 边界均有测试。
- [ ] B 单元 READY；截图不能替代源码和日志。

## C 单元

- [ ] IF_V1、IF_V2 bridge 与 v3 端口差异表完成。
- [ ] bank mapping、buffer lifecycle、active-write rejection 通过。
- [ ] 真实 XPM/Vivado 证明 N+2 response 且 response 无回压。
- [ ] epoch/abort/reset、CDC FIFO、4 KiB split、短尾通过。
- [ ] 正常 counter：`rd_beats=196608`、`wr_beats=131072`、`rows_committed=4096`。
- [ ] conflict/protocol/error/underflow/overflow 均为 0。
- [ ] C memory-service/OOC READY。

## 集成发布

- [ ] A/B/C/compute wrapper 均 READY 且接口 tag 一致。
- [ ] 150 MHz elaboration、OOC、synthesis、implementation、timing、DRC 全通过。
- [ ] 2/4 cluster 分阶段验证；200 MHz 独立提交。
- [ ] production manifest、board top、BD、constraints 获队长批准。
- [ ] BIT/XSA/ELF 仅在整板门禁通过后生成并记录哈希。

状态规则：`NOT READY` 可以提交 checkpoint；`READY` 必须有证据；未运行不得标 PASS。
