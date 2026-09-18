# D2 CATS-R4 独立验证与 Telemetry 冻结契约

日期：2026-09-09  
接口：`CATS_R4_INTERFACE_V3_COMMIT`  
接口 commit：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`  
证据范围：软件参考、历史原件身份、协议检查器自测和计数公式；不包含新 RTL、XSim、OOC、实现或板测。

## 1. 数值参考

保留两套明确分离的参考：

1. 项目语义参考：BF16 输入、项目声明的 QK score 舍入、Compatibility 的既有语义，以及 v3 Accuracy 的完整行 max、FP32 weight、key 顺序 FP32 sum/PV、reciprocal+multiply 和最终 BF16 RNE。
2. 独立数学参考：稳定 softmax `exp(score-max)`，高精度/FP64 sum 和 PV，最终仅做一次 BF16 RNE；不读取生产 exp LUT，不复制生产 reciprocal 或状态机。

固定比较门禁：`absolute_error <= 1e-4 OR BF16 ordered ULP distance <= 1`。该阈值是项目契约，不声明为官方比赛规则。

每份数值报告必须包含：elements、different、strict_abs_failures、over_one_ulp、combined_failures、max_abs_error、max_ulp 和最坏元素坐标。

## 2. 固定测试矩阵

- full：32 heads × 128 rows × 128 features，共 524,288 outputs。
- 历史 stress：seed 20260905、32 cases、4,096 outputs。
- 已知复现：seed 12794、1 case、S=D=128、tile=4。
- 独立参考自测：相等 score、后部最大值、长尾、正负 V 抵消、causal row 0/127、短行及固定随机样本。
- 非法数值：NaN/Inf score、负/非有限 weight、sum<=0、非有限 inv_sum、numeric_mode 2/3。
- 协议：valid/ready stall stability、mask/last、token 唯一性、slot owner、N+2 response、outstanding、release、reset/epoch 和错误注入。

历史事实必须保持：

- full 四个软件候选 `combined_failures=0`，但不是硬件结果。
- stress 的 online_q15/row_q15/row_fp32_exp_software 分别为 482/459/0；Python exp 不等于硬件 exp。
- seed 12794 的 fused-vs-math 为 10、fused-vs-v30 为 13、v30-vs-math 为 23；不得删除或放宽阈值。

## 3. Token 与协议断言

共同 token：`epoch, group, global_q_head, row, slot_id, numeric_mode`。要求 `group == global_q_head >> 2`，slot_id 为 0..2，numeric_mode 为 0/1。

所有 valid/ready channel 在 stall 时保持完整 payload/token/mask/last 稳定。每行 weight key 必须按 0..127，mask 必须等于 `key > row`，last 仅允许 key=127。masked data 必须为 +0。row_commit 只能在 128 次写入后发生；pv_row 只能针对已封存行；release 只能在 outstanding=0 且最后输出已接受后发生，且每 token 恰好一次。

weight read response 必须对应已接受请求，request=response；集成 RTL 到达后再检查精确 N+2 时序。本 D2 自测只证明 checker 能接受合法序列并拒绝指定非法序列。

## 4. Full workload 固定计数

| 项目 | 期望值 |
|---|---:|
| valid exp | 264,192 |
| valid QK MAC | 33,816,576 |
| valid PV MAC | 33,816,576 |
| Context words | 524,288 |
| weight writes（含 masked 零） | 524,288 |
| row_commit | 4,096 |
| pv_row | 4,096 |
| weight_release | 4,096 |
| DDR read beats | 196,608 |
| DDR write beats | 131,072 |
| rows_committed | 4,096 |

有效计算量与存储流量分开。masked 项允许存零但不能计入有效 exp/PV。1/2/4 cluster 的 aggregate 有效工作量不得随复制增加。

## 5. Telemetry schema

每条事件至少记录：schema_version、candidate commit、interface tag/commit、numeric mode、clock domain、cycle/timestamp、epoch、group、global_q_head、row、slot_id；适用时增加 key、feature、seq、mask、last、valid、ready 和唯一 request/result/commit id。

计数至少覆盖：

- weight：write/read request/read response、row commit、pv row、release、outstanding max。
- workload：valid exp、QK/PV MAC、Context words、groups/q_heads/rows done。
- stall：RAW、bank、FIFO、DMA、AXI、output、reorder。
- FIFO：push/pop/max occupancy/full/empty stall/underflow/overflow。
- error：owner、mask、last、mode、numeric、epoch、bank conflict、tag/seq、AXI response。

正常用例所有 error/protocol/conflict/underflow/overflow 必须为 0。stall 不要求为 0，但必须能解释周期。

## 6. 计时边界

- core：cluster 接受 command 到 group done。
- PL transaction：PL 接受 transaction 到全部 Context 写回及 counter snapshot。
- application：软件准备/启动到软件确认完成。

不同 clock domain 的 cycles 不直接相加；每项记录频率和换算时间。规划目标不得写成实测。

## 7. D2 READY 含义

D2 READY 只表示验证契约、参考自测、历史身份检查和 checker 自测可用，不表示 A/B/C 实现 READY。B2/RTL/XSim/OOC/板测缺失时对应字段必须为 `NOT RUN`，不会阻止验证契约自身 READY；正式候选签核和消融在 D3 进行。
