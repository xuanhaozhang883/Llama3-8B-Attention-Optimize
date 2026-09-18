# D 对 IR-A4-06 的正式决定：性能边界与自动门槛

日期：2026-09-16  
状态：**D ACCEPTED；等待 A/C 在远端集成请求表登记**

## 1. 周期边界

- `start_cycle`：本次事务第一个合法 QK issue 在 A 的发射边界完成 `valid && ready` 接收的周期。
- `end_cycle`：最后一个 canonical Context chunk 在 C 冻结的 production acceptance boundary 完成 `valid && ready` 接收的周期。
- `elapsed_cycles = end_cycle - start_cycle + 1`。

在 C 尚未冻结“最终 Context 接收点”之前，只能记录候选测量，不能出正式 speedup 签核。

## 2. N=2 性能门槛

在相同输入哈希、numeric mode、lane 配置、时钟、shape、causal 规则、输出顺序和反压策略下：

`speedup2 = elapsed_cycles_N1 / elapsed_cycles_N2`

自动门槛：`speedup2 >= 1.60`。模型预测只能用于规划，不能替代测量。

## 3. 不平衡门槛

对正常负载，分别检查两集群的 work 与 busy：

`imbalance(x0, x1) = abs(x0 - x1) / max(x0, x1)`

要求：

- `work_imbalance < 0.05`
- `busy_imbalance < 0.05`

若分母为 0，则该条测量无效；不能按 0% 通过。

## 4. 可比性与守恒条件

N=1/N=2 两次证据必须同时满足：

- 输入文件及关键参数 SHA256 相同；
- mode、lanes、shape、clock、reset、causal/mask 规则相同；
- 输出 canonical ordering 与 backpressure 配置相同；
- error/fatal/timeout/overflow/underflow/owner mismatch 均为 0；
- groups、rows、jobs、retires、Context chunks 的预期值与观测值全部守恒；
- 报告包含完整 commit SHA、dirty 状态、命令、工具版本、seed 和原始日志哈希。

## 5. 当前判定

IR-A4-06 的 D 决策已经完成，但 A4 远端响应表仍显示 OPEN。该 OPEN 是“决定尚未合入远端”的协作状态，不代表 D 尚未给出判定。真实 N=2 测量仍因 C 输出边界和真实双 A3/C 数据面未完成而不可执行。

