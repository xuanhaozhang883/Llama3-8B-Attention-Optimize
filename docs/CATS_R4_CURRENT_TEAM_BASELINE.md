# 当前团队入口：2026-09-08

队长决议：本轮发布的是开发契约与历史资料恢复，不是生产 READY。
基于 `9c89ed2859d44ecf17c5ee5f39acbee55c98adaf`；分支 `codex/cats-r4-local-integration`。
发布身份以 annotated tag `CATS_R4_INTERFACE_V3_COMMIT` 解析出的完整 commit 为准。

## 交给队友的操作

先保存个人工作树为明确标记 NOT READY 的 checkpoint；不要覆盖未提交工作。
然后在仓库执行：

```powershell
git fetch origin
git fetch origin tag CATS_R4_INTERFACE_V3_COMMIT
git rev-parse 'CATS_R4_INTERFACE_V3_COMMIT^{commit}'
git show CATS_R4_INTERFACE_V3_COMMIT:docs/CATS_R4_INTERFACE_V3.md
```

由队长协调将冻结提交合入个人分支，或从 tag 新建独立工作树；不要直接覆盖整个队友目录。
合入后执行：

```powershell
python tests/check_cats_r4_lead_release.py
python tests/test_cats_r4_v3_capacity.py
```

## 文件入口与边界

- [v3 接口](CATS_R4_INTERFACE_V3.md)：FP32 weight、token、握手、两周期无反压读、容量与计数；supersedes 对应旧接口条款，旧 tag 不动。
- [当前协作规范](CATS_R4_TEAM_RULES_2026-09-08.md)：C 兼队长，A/B/C 按模块负责。D 表示独立验证职责；若团队只有三人，由队长安排交叉复核，不要求新增第四个人。
- [两份原始报告及出处](architecture_study_20260905/README.md)：恢复原件，不伪造占位结果。

本轮实测：4 个归档 SHA256、8 个输入 SHA256、JSON 范围/历史指标检查 PASS；
v3 容量/bank bijection/workload/非法cluster参数共4测试 PASS。
这只是资料与规划算术检查，没有运行新的 RTL、硬件数值、XSim 或 OOC。

## 当前未解除的问题

1. B 的截图对应源码仍未提交到可审查的远端分支；先交分支和完整 SHA、TB、复现命令与日志。
2. Accuracy exp/sum/reciprocal 与 PV 实现、精度签核尚未完成，v3 冻结不代表实现通过。
3. C 的 IF_V1/IF_V2 对照和真实 XPM latency 仍须验证；不能只改版本注释接生产系统。
4. 全板门禁未解除，本轮没有更改 production manifest、board top、约束或生成 BIT/XSA/ELF。

下一轮优先：接收 B2 checkpoint → C 集中工具验证，同时 A/B/C 消费 v3 做单元开发。
收到端口不一致必须显式报告，不默默兼容；接口再变更用新版本、新测试、新 tag。
