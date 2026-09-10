# D2 CATS-R4 验证结果

日期：2026-09-09  
状态：**READY（仅验证契约和软件工具）**

## 结论

D2 的接口身份、输入身份、历史报告、独立参考自测、协议 checker 自测、workload/counter 公式、已知 seed 复现和完整 full-GQA 软件重算均已通过。该结论不代表 CATS-R4 RTL、XSim、OOC、整板实现或板测 READY。

## 实际执行结果

| 检查 | 结果 | 关键数据 |
|---|---|---|
| v3 接口身份 | PASS | `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee` |
| 历史原件与输入身份 | PASS | 4 个归档 SHA-256、8 个输入 SHA-256 全部匹配 |
| v3 容量与 workload | PASS | 4/4 tests |
| 独立参考交叉检查 | PASS | FP64 vs Decimal(80)，522 outputs，combined_failures=0 |
| 协议 checker 自测 | PASS | 2 个合法 token；5 类错误全部检测 |
| full-GQA RTL-exact 软件重算 | PASS | 524,288 outputs，combined_failures=0 |
| seed 12794 | PASS（风险复现） | fused-vs-math=10，fused-vs-v30=13，v30-vs-math=23 |
| 当前模型 stress | 完成（风险保留） | fused-vs-math=136，fused-vs-v30=567，tile-vs-scalar=0 |
| 新 CATS-R4 RTL/XSim/OOC/板测 | NOT RUN | 尚无完整 B2/B3/A/C 候选 |

## Full-GQA 数值明细

- elements：524,288
- different：223,988
- strict absolute failures：3
- over-one-ULP：79,355
- combined failures：0
- max absolute error：0.0001220703125
- max ULP：28,309

`combined_failures=0` 的原因是门禁为 `abs<=1e-4 OR BF16 ordered ULP<=1`：绝对误差超过阈值的 3 个元素仍满足 1 ULP；ULP 较大的近零元素满足绝对误差阈值。因此只能表述为“组合误差门禁通过，非 bit-exact”。

## Stress 结果解释

历史 row-candidate stress 报告仍固定为 online_q15=482、row_q15=459、row_fp32_exp_software=0。当前重跑的 `flash_attention_tile_model.py` 是另一套 fused/v3.0 诊断模型，得到 fused-vs-math=136、fused-vs-v30=567、v30-vs-math=598；两组数字适用模型不同，不应相互替代。

这些失败不会阻止“D2 验证契约 READY”，但会阻止相关数值候选在 D3 中被标为实现 READY，除非 B 的真实 Accuracy 实现按相同输入和门禁重新通过。

## 已知限制与下一依赖

- Windows `core.autocrlf=true` 曾改变五个输入/参考文件的字节身份；本次已恢复并通过哈希，后续需冻结跨平台 EOL 规则。
- Python `math.exp`、Decimal 参考和历史软件模型都不是硬件 exp/reciprocal 证据。
- 当前没有 B2 Accuracy RTL、真实 RTL event log、XSim、OOC、全板实现或新板测，全部为 NOT RUN。
- 等待 B2/B3、A compute-cluster 和 C single-board 的完整 branch、commit、TB 与日志，再按本契约进入 D3 独立审查和公平消融。
