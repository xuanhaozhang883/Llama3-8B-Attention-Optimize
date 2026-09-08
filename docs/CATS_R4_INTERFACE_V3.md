# CATS-R4 v3：队长冻结的 Accuracy weight 接口

日期：2026-09-08。状态：LEAD FROZEN FOR UNIT DEVELOPMENT；团队实现验证待交付。
版本：`CATS_R4_IF_V3 = 0x0003_0000`；发布 tag：`CATS_R4_INTERFACE_V3_COMMIT`。
本次由 C 负责人兼队长决定接口，未声称已取得 A/B/D 的实现签核。

## 版本关系与适用范围

v1 tag 不移动，v2 文档不覆盖。v3 明确纳入 v2 的独立 Q/KV selector、Q-slab
need/ready/retire 握手和每 group 32 slabs；新增下述 B→C→B weight 与行元数据接口。
v1 的 16-bit opaque weight 不能承载 Accuracy FP32，本版本对此作 breaking change。
QK 对外 score 仍为 BF16，V/Context 仍为 BF16；本次不改变 A 的 score 舍入边界。
沿用 v2 的 32 key lanes、四个 Q head 顺序复用；PV 为单 head 的 32 features。
旧方案“4 heads×8 lanes”不得和此映射混用，若需该拓扑必须另提版本。

## 模式与数值含义

`numeric_mode[1:0]`：0=Compatibility，1=Accuracy，2/3非法。
模式是构建配置，在一次事务 start 时锁存；busy 期间不得切换。不要求首版实现动态切换。
配置不支持的模式必须拒绝 start 并计错，禁止静默退回另一模式。

Accuracy weight 是未归一化的 `exp(score-row_max)`，按 IEEE binary32 raw bits 存储。
同一行先求完整 max，再按 key 递增产生 weight、FP32 顺序累加 sum。
不经 BF16/Q15 中间转换，不继承 score-max<-8 截断；mask key 的存储值为 +0，
不计有效 exp/PV 工作。合法 causal row 至少一个有效 key。
PV 保持 key 顺序，FP32 乘法和加法分开舍入（RNE，禁止未声明 FMA/树形归约），
行末使用 FP32 reciprocal 后乘法归一化，再做 BF16 RNE。
exp/reciprocal 的近似实现仍须 B 提交精度与特殊值测试，不由接口冻结假定通过。
非有限 score、非有限/负 weight、sum<=0、非有限 sum/inv_sum 均终止该行并计数，禁止发布正常完成。
有限下溢结果必须在 B 的算术交付中声明与验证，不能依赖不同工具的隐式行为。

Compatibility 保留 B 声明的 BF16 weight raw bits，放在统一 32-bit payload 的低16位，
高16位必须为0；PV 读取时按 BF16 解释低位。不得把它直接当 FP32。
Compatibility 的 exp/reciprocal 既有语义需在 B2 数值交付中明确，v3 不重新定义其算法。
软件研究报告使用的最终 division 和本接口 reciprocal+multiply 边界不同，须分别回归。

## 共同 token 与所有权

全部 channel 在 core_clk 域。token T 含 `epoch[15:0], group[2:0],
global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0]`，slot_id=0..2。
group 必须等于 global_q_head[4:2]。本地 cluster_id 为实例常量，不从 token 推导跨 cluster 仲裁。
同一 epoch 内 token 不得重复分配；slot 重用必须等待 release，整个行身份必须逐项匹配。

A 的 score row 完整后交给 B，B 持有 SOFTMAX 写权；B→C 的 row_commit 完成后
weight slab 封存。C→B 的 pv_row transfer 才转为 PV 读权；PV→C 的 release
仅在最后输出已被接受且读 outstanding=0 时允许。release 后方可 FREE。
所有 valid/ready channel 在 stall 时保持全部字段稳定。clear/reset 由集成 reset controller
统一执行，先隔离流量并清 outstanding；旧 epoch completion 丢弃、epoch_drop计数，不允许写入新槽。

## 精确信号与时序

| 前缀 | 方向 | 字段（前缀加下划线） | 语义 |
|---|---|---|---|
| weight_wr | B→C | valid/ready、T、key[6:0]、mask、data[31:0]、last | 每行按key=0..127写128项；last只在127；mask=key>row；masked data=0 |
| row_commit | B→C | valid/ready、T、sum_fp32[31:0]、inv_sum_fp32[31:0] | 128项写入完成且数值合法后一次提交，存储元数据 |
| pv_row | C→B | valid/ready、T、sum_fp32[31:0]、inv_sum_fp32[31:0] | 向PV发布已封存行；反压期间稳定 |
| weight_rd_req | B→C | valid/ready、T、key[6:0] | 只允许PV owner；ready时II=1 |
| weight_rd_rsp | C→B | valid、T、key[6:0]、mask、data[31:0] | 无ready；请求在N边沿接受，在N+2边沿后产生有效响应；consumer须保证容量 |
| weight_release | B→C | valid/ready、T | outstanding=0且PV输出已被接受后释放，恰好一次 |

weight读为scalar，由B向32个feature lane广播。同周期仅允许一个读请求和一个写请求；
不同slot可并行。bank=key[4:0]，addr=key[6:5]；每slot为32 banks×4×32bit。
同槽封存后不可写，任何同bank同址非法写/非法owner都拒绝transfer并置sticky error。
数据RAM不要求reset清零；有效位、owner、计数、读流水必须清空，未写数据不能读。

## 容量与计数

为避免复用score导致覆盖，首版每cluster保留三份score16槽，并另设三份weight32槽。
score=3×128×2=768 bytes（既有）；新增weight=3×128×4=1536 bytes。
sum与inv_sum元数据另增3×8=24 bytes；相对C1逻辑规划152960 bytes增至154520 bytes，
尚不含新增token/control bits。1/2/4 cluster新增1560/3120/6240 bytes，非综合BRAM预测。
R=16 QK contexts 与三行槽的调度需A证明反压/容量；不得自动将三槽改称16行slab。

64-bit owner-domain counters：weight_wr_accept、weight_rd_request、weight_rd_response、
row_commit_count、pv_row_count、weight_release_count、owner_error、mask_error、
last_error、mode_error、numeric_error、epoch_drop、bank_conflict、outstanding_max。
full正常事务：row_commit=pv_row=release=4096，weight_wr_accept=524288（含masked存储），
有效exp=264192，QK/PV MAC分别33816576，Context words=524288；
读计数按实际请求闭合request=response，不把广播/重复feature chunk读取算成新增exp。
DDR read=196608 beats、write=131072 beats、rows_committed=4096保持不变。
负向测试允许指定错误counter增加，不能拿负向用例的非零计数判正常负载失败。

## 发布门禁

此冻结解除“Accuracy FP32 weight接口未定”的单元开发阻塞，允许A/B/C并行开发、
提交NOT READY checkpoint。它不代表Accuracy exp/PV已实现，也不替代真实XPM、
CDC、OOC或整板验证。A/B/C/D回报消费的tag和commit；不匹配处提出显式端口diff。
全板接入仍须A/B/compute wrapper及C memory集成证据通过；150 MHz先行。
