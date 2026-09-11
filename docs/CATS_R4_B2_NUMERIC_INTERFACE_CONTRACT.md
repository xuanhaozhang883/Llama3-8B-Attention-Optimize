# CATS-R4 B2 整行 Softmax 数值与局部接口契约

状态：`LOCAL CHECKPOINT / NOT READY`

Owner：成员 B

当前集成基线：A2 `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb`；
abort/cancel 窄修复 HEAD `a26cdc5ee64e12884fc9e529213ba6630202356b`。

目标：XCZU15EG-FFVB1156-2-I、Vivado 2025.2、`S=D=128`、
`32Q/8KV`、BF16 I/O、causal prefill。本文消费但不修改
`CATS_R4_INTERFACE_V3_COMMIT`，不修改公共 top 或生产 manifest。

## 1. 证据边界

annotated tag `CATS_R4_INTERFACE_V3_COMMIT` 解析到
`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`。v3 已冻结 32-bit weight payload、
三 slot token/ownership、row commit、两周期无反压 weight read 和计数边界。A2
提交 `d06d999` 已提供精确 A→B row/score/max channel，并由 B 的 full Icarus handoff
回归验证 4,096 rows / 264,192 causal scores。

两份历史报告已恢复到 `docs/architecture_study_20260905/`。B 模型固定并验证报告
SHA-256、schema、full/stress 范围、8 个当前输入 hash 和原始指标。报告只有聚合
软件结果、没有逐行向量，不能据此声称当前 RTL 重放通过；stress 中
`row_q15=459/4096` 与 `row_fp32_exp_software=0/4096` 必须原样保留。

## 2. 统一的整行算法

两种模式都必须先获得完整行的全局 max，再按 `key=0..row` 的严格递增顺序
生成 `exp(score-max)` 并累加 row sum。上游不得发送严格上三角 key；若局部
wrapper 为调试接受 masked item，该 item 输出零且不计入有效 exp 工作量。

本阶段不保留 online 跨 tile `m/l/O` 递推，不执行旧 O-state 重缩放。模式只由
显式配置常量选择，禁止根据文件名、输入 hash、head/row/key、测试 seed 或特殊
向量身份切换。

## 3. Compatibility 数值语义

Compatibility 明确保留现有项目 RTL 的以下边界：

1. score/max 均由 BF16 转为 signed Q10.14；沿用现有饱和与舍入函数。
2. `delta=max-score` 在 Q10.14 计算；LUT 地址为
   `round_nearest(delta*64)`，即 fixed delta 加 `2^7` 后右移 8 bit。
3. `delta>8` 时 exp 为 0；`delta=8` 读取地址 512。该截断只属于
   Compatibility，Accuracy 不继承。
4. exp 为 `exp_lut_q15.mem` 的 unsigned Q1.15；weight slab 写入该 Q15 值经
   RNE 转换后的 BF16。row sum 按 key 顺序对原始 Q15 exp 做无饱和整数求和，
   `S=128` 时需要 23 bit。
5. reciprocal 为 `floor(2^45/sum_q15)` 的 unsigned Q1.30，并沿用现有
   `q30_to_fp32` 规格化语义。若全部 masked/sum=0，weight、reciprocal 均为 0，
   同时由 wrapper 置 row error。
6. 为保持项目 RTL 语义，unmasked BF16 NaN 在 score→Q10.14 时映射为 0；
   ±Inf 按现有饱和规则映射。实现必须增加 special-value counter，不能静默
   把 Compatibility 的映射宣称为 IEEE 数学语义。

## 4. Accuracy 数值语义

Accuracy 当前候选边界为：BF16 RNE 后的 score/max 输入；有限值转为有符号
Q16 后计算 `max-score`，并在 104 饱和；exp 使用 Q16 `log2(e)=94548/65536`
范围缩减、整数指数移位和 32 段/33 项 Q31 `2^-fraction` LUT 线性插值，最终
RNE 编码为 FP32 weight。按 key 顺序的 row sum 使用正有限 FP32 RNE 加法；
`1<=sum<=128` 的 reciprocal 使用 `2^47/significand` 整数除法和 ties-to-even
舍入生成 FP32。进入 B3 PV 前保持 FP32 weight；最终 Context 才 RNE 到 BF16。
禁止默认 `score-max<-8` 截断。

独立 Accuracy 边界仍用 host `exp`；硬件导向候选对 16/32/64/128 段使用同一
stress seed 消融：16 段有 3 个 combined failure，32/64/128 段为 0。32 与 64
段再跑完整 4,096 行、524,288 Context 元素均为 0，因此当前选择最小的 32 段。
固定候选用 33 个 Q31 LUT 点，exp、positive FP32 add 和 reciprocal 各自通过
8,192 组 RTL/模型逐位回归；三者已组成三槽整行 Accuracy core 和方案 A V3 wrapper。
存储 Q/K/RoPE 派生的全部 4096 行、264192 个 score 已对 weight/sum/inv_sum 逐位
回归，并完成 524288 次 C 侧写入计数闭合；这些仍不是 XSim、OOC、PPA 或板级证明。

特殊值按 v3 执行：masked 值不参与；任一 unmasked score 非有限（NaN 或
`+/-Inf`）时该行 `numeric_error=1`，不发布 exp/weight/正常 row commit。有限
`exp` 下溢允许产生 IEEE binary32 `+0`，但必须由硬件实现和测试明确验证，不能
依赖工具隐式模式。任何规则都不能按测试身份改变。

## 5. 项目 RTL 参考与独立数学参考

- 项目 RTL 参考：`compatibility_row`，逐位镜像 Q10.14、Q15 LUT、BF16 weight、
  Q*.15 sum 和 floor reciprocal。
- Accuracy 候选：`accuracy_row_fixed`，逐位镜像当前 Q16/Q31 exp，并保留显式
  FP32 sum/reciprocal 边界；`accuracy_row` 仍作为 host-exp 对照。
- 独立数学参考：`independent_probabilities`，用 BF16 解码值和高精度 row
  max/exp/sum 构造结果，不调用项目 LUT、截断或 reciprocal。

误差规则继续使用既有 `Metrics` 的固定规则：只有当 absolute error `>1e-4`
且 BF16 ULP distance `>1` 时计 combined failure。B 不修改 golden、阈值或原始
日志；combined Gate 通过也不得写成 bit-exact。

## 6. v3 边界与 B-owned wrapper

共同 token `T={epoch[15:0], group[2:0], global_q_head[4:0], row[6:0],
slot_id[1:0], numeric_mode[1:0]}`；`group=global_q_head[4:2]`，slot 仅为 0..2，
mode 仅为 0=Compatibility、1=Accuracy。当前 Compatibility 原型中的 4-bit
`context_tag` 只是旧局部测试身份，不可直接冒充 v3 slot/token。

B→C `weight_wr` 必须对每行按 key=0..127 写 128 项；`mask=key>row` 的 payload
为零且不计有效 exp/PV。Compatibility payload 高 16 位为零、低 16 位为 BF16；
Accuracy payload 是 FP32 raw bits。最后一项仅 key=127 置 `last`。B→C
`row_commit` 只在 128 项完成且数值合法后发布 `T,sum_fp32,inv_sum_fp32`。

队长已冻结方案 A：每 cluster 使用三份 128x32-bit 本地 staging；全部 causal weight、
sum、inv_sum 验证成功前对 C 零写。成功 finalize 后才固定发布 128 项；完成 128 次
accepted write 后才允许 row_commit。错误行使用 B 本地错误报告/全局 clear，不新增
V3 `weight_abort`。row_commit 后 slot 仍保持 HELD，直到 B3 最后输出、C release 和 A
final_release 协调完成。逻辑数据容量为 1536 B weight + 24 B sum/inv = 1560 B/cluster，
实际 BRAM/LUTRAM 以 OOC 为准。

所有 valid/ready channel 只在握手时传输，stall 时全部字段稳定。`clear` 只清
active/token/在途数据并丢弃旧 epoch completion；`reset` 清全部状态和计数器；
`counter_clear` 只允许在 B wrapper 无 owner 的 quiescent 边界使用，并清全部
B-owned 计数器与 sticky indication。score
token、key 顺序、last、row max、epoch/mode 任一不匹配时阻止正常提交并计错。
公共 top 由 C/队长接入，B 只提交稳定 wrapper 和端口差异。

## 7. Counter 与阶段门禁

必须分别提供 row、exp、有效 weight、sum、reciprocal 的
`issue/result/commit`，以及 output/backpressure、sum dependency、context reuse、
tag/key/last/epoch/special/numeric error。完整 causal 工作量为：

- rows/reciprocal：`32*128 = 4,096`；
- 有效 exp/weight/sum：`32*sum(1..128) = 264,192`。
- v3 `weight_wr_accept`（包含 masked 零写）：`4,096*128 = 524,288`。

所有 issue/result/commit 必须分别相等；不能用期望常量冒充 RTL counter。
随机 backpressure/reset 不得死锁、丢 tag、重复 weight 或覆盖 context。

B2 只有在正式 full/stress/随机数值、直接 TB、随机反压/reset、一个系统回归、
XSim、全新 root OOC synthesis、WNS≥0、PPA、`git diff --check` 全部有原始证据
后才可标 READY。队长已冻结“Compatibility/Accuracy 算术 core 在 finalize 前仲裁、
只使用一套三槽 stager”的方案 A；B 的
`cats_r4_b2_shared_stager_v3_wrapper.sv` 已实现该局部封装，slot 持有锁存后的
mode/token/epoch，两个 locking arbiter 在 weight/finalize 前仲裁，且仅例化一个
`cats_r4_b2_weight_stager`。A 的 `cats_r4_qk_a2_row_pipeline` 已在 txn_start
握手时锁存 mode，B 不按 row 或测试身份重新选择模式。

历史 JSON 身份门禁、A→B score/max 交接和本地 Icarus shared-wrapper 回归均已通过，
但这不等于实现门禁；随机上游 row/score 压力与 reset 多 seed、C 实际存储/最终
release、A 对 abort commit 的接收，以及 Vivado 2025.2 XSim/OOC/PPA/WNS 证据
仍缺失。因此状态保持 `NOT READY`，且不进入 B3。
