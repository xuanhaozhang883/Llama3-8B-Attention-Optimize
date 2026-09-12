# CATS-R4 B4 成员 B 集成交付记录（2026-09-13）

## 状态与代码身份

- 阶段：`B4 Softmax/PV tag、反压、数值传播与 1/2/4-cluster 回归`。
- B-owned 状态：`GATES PASS / READY TO COMMIT AND HAND OFF`。
- 系统状态：`NOT READY`；A/C 尚未把本 wrapper 接入 production cluster/weight/V service
  和 board top。
- branch：`member-b-cats-r4-a2-integration`。
- B4 base / 测试时 HEAD：`07a1c87239349ae7bfe986ad78694f88f1f6fe93`。
- interface baseline：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
  (`CATS_R4_INTERFACE_V3_COMMIT`)；当前分支已消费该基线。
- B4 commit：本文件所在的 `B-integration-fix` commit；提交后以 `git rev-parse HEAD`
  为准，不在提交内容中写不可自引用的 commit SHA。

工作区另有用户自己的 README、板级脚本、日志和 artifacts 修改。本提交不修改、暂存
或删除这些文件，也不修改 A 的 QK/scheduler/cluster 控制、C 的 AXI/DMA/CDC/board top
或 D 的 golden、阈值和原始日志。

## B-owned 交付文件

- `rtl/core/bc/integration/cats_r4_b4_softmax_pv_cluster.sv`
- `rtl/core/bc/softmax/cats_r4_row_softmax_accuracy.sv`
- `tb/tb_cats_r4_b4_b2_protocol_model.sv`
- `tb/tb_cats_r4_b4_b3_protocol_model.sv`
- `tb/tb_cats_r4_b4_c_weight_model.sv`
- `tb/tb_cats_r4_b4_multicluster.sv`
- `tests/run_cats_r4_b4_multicluster_iverilog.ps1`
- `tests/run_cats_r4_b4_realip_vivado.ps1`
- `docs/CATS_R4_B4_DELIVERY_2026-09-13.md`

关键 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `cats_r4_b4_softmax_pv_cluster.sv` | `5E11FC43497D11BCA87CCCC4BD1CD2B9ABA8635E29DB064623EEF0733A5DF24E` |
| `cats_r4_row_softmax_accuracy.sv` | `39C467E3AFD1D2FE2A74F3C7B1EA00E19F618063AC099F5CBAF278FA71E21ECE` |
| `tb_cats_r4_b4_multicluster.sv` | `DA4A046F8E12099F3467E4665BEAAB964937F4D2BA518EEFD0AED5FA14AAD841` |
| `tb_cats_r4_b4_c_weight_model.sv` | `99A0201EC00BABC1F0805E51DF1551E0A79F8BAA93D5A78DDCF421CE00DB2F92` |
| `run_cats_r4_b4_multicluster_iverilog.ps1` | `39226A75317FFAAEED0401D036A94D2A8B357998364BF09EA14A1466FC78F152` |
| `run_cats_r4_b4_realip_vivado.ps1` | `D6C9EF7F291306164D8B1D42CB9FAD7CDBE17F5D744EE6E9833FE886B797FB42` |

## 实际集成与修复

`cats_r4_b4_softmax_pv_cluster` 组合实际 B2 shared stager 与实际 B3 32-lane PV，
并保持全部 V3 B<->C channel 外露；它不吸收 C-owned weight/V 存储。正常释放顺序为：

1. 捕获 B3 在最终 Context accepted 且 outstanding 清零后的 release；
2. 将同一完整 token 分别交给 C weight release 和 B2 internal slot release；
3. 两个 owner 都接受后才向 A 发布 final score-slot release；
4. B2 pre-publish error 对 C 零写入，错误路径跳过 C release，在 error report accepted
   后释放 B2 slot，再向 A 发布 final release；
5. error 与 normal release 同周期竞争时 error 优先，stalled release payload 保持稳定。

本阶段对 Accuracy 的唯一算术修复是 RAW forwarding 条件：stalled FP32 add result 已占有
elastic output 时，下一输入本来就不能被接受，因此 bypass 只由已登记 result 的 slot
identity 决定；结果真正被接受的同周期继续向同 slot 下一 key 转发。这消除了 reciprocal/
output backpressure 被错误引入 add data path 的问题，没有改变数值模式、舍入或阈值。

## 数值结果与参考身份

B4 沿用 B2/B3 已冻结、未放宽的独立数学与项目 RTL 语义：

- Accuracy stress：seed `20260905`，32 cases、4096 elements，
  `combined_failures=0`。
- Accuracy stored full：4096 rows、264192 个有效 exp/PV weight、524288 个 Context
  element，`combined_failures=0`。
- full 的 `strict_abs_failures=18`；最大绝对误差 `0.0001220703125`，最坏元素
  head=4、row=1、feature=84，实际/期望为 `0xBC8B/0xBC8A`，BF16 distance=1。
- combined gate 采用未修改的 `abs<=1e-4 OR BF16 distance<=1`，因此 PASS 不是
  bit-exact。
- Compatibility 正式 full 软件候选 `combined_failures=0`；历史旧 Q15 stress
  `459/4096` failures 原样保留，未声称为全合法 stress PASS。

权威 full/stress JSON SHA-256：

- full：`1FE8CC632C0CEF75D735CE9CD5F89778E1B5CF11D15F7A030555B04DC8D3DC86`
- stress：`85BD41563851EB98B743607A0078C639C97C4A708F5EF6AD2354D602E88FC60A`

## 1/2/4-cluster 回归与计数闭合

### Full aggregate 协议回归

命令模板：

```powershell
tests/run_cats_r4_b4_multicluster_iverilog.ps1 `
  -Clusters <1|2|4> -Mode <0|1> `
  -GlobalHeads 32 -RowsPerHead 128 -Seed 3019898881 -ProtocolModels
```

1/2/4 cluster x Compatibility/Accuracy 六项全部 PASS；每项的全局 workload 不随
cluster 数复制：

| counter | aggregate actual |
|---|---:|
| rows / final releases | 4096 / 4096 |
| valid exp | 264192 |
| weight writes | 524288 |
| effective PV MAC | 33816576 |
| Context words | 524288 |
| B2/B3/C/release error | 0 |

原始日志：`artifacts/b4_multicluster_full_final_20260912/`；6 logs、6 aggregate PASS、
0 runtime FAIL/Fatal。该 full 使用协议模型替代耗时的重复算术，但实际 B4 wrapper、
C ownership model、ready/valid/backpressure 和全部计数路径仍参与；它不单独证明
Compatibility/Accuracy 算术。

### 随机协议压力与错误释放

```powershell
tests/run_cats_r4_b4_multicluster_iverilog.ps1 `
  -Clusters <1|2|4> -Mode <0|1> `
  -GlobalHeads 4 -RowsPerHead 16 -Seed <7|19|73|101> -ProtocolModels
tests/run_cats_r4_b4_multicluster_iverilog.ps1 `
  -Clusters 1 -Mode <0|1> -GlobalHeads 1 -RowsPerHead 1 -ErrorRelease
```

四个 seed x 三种 cluster scale x 两个 mode 共 24 项全部 PASS；每项 aggregate 为
64 rows、544 exp、69632 PV MAC、8192 Context、64 releases，所有正常路径 error counter
为 0。覆盖随机 row/score/weight/V/output/release backpressure、固定 N+2 weight response、
owner/token/epoch、三个 slot 占满与复用、commit/release 守恒。原始日志：
`artifacts/b4_multicluster_random_final_20260912/`。

修改后重新执行的 error-release mode 0/1 均 PASS：1 report、0 write、0 C release、
1 B2/final release；定向协议/数值错误只按预期计数一次。

### 真实 B2+B3 算术与依赖回归

修改后重新执行 1/2/4 cluster x 两种 mode 共六项 arithmetic smoke，全部 PASS；它编译
实际 B2 shared wrapper 和实际 B3 controller/MAC/normalize。Icarus 下 FP operator 使用
B3 定向 arithmetic mock；每 cluster 两行、3 exp、384 PV MAC、256 Context，Context
逐字检查为 BF16 1.0。

以下依赖回归也在当前工作树重跑并 PASS：

```powershell
tests/run_cats_r4_a2_b2_shared_iverilog.ps1
tests/run_cats_r4_b3_pv_32lane_iverilog.ps1
tests/run_cats_r4_b3_pv_controller_iverilog.ps1
tests/run_cats_r4_b2_accuracy_fixed_model.ps1
tests/run_cats_r4_b3_pv_full_workload_iverilog.ps1
```

最后一项实际闭合 4096 rows、264192 weight request/response/consume、1056768 V
request/response/consume、33816576 PV issue/result/commit、524288 Context、4096 releases；
output stall cycles=`5869`，protocol/numeric/epoch error=`0/0/0`。

## Vivado 2025.2 XSim

真实 Floating Point Operator 的 1/2/4 cluster x Compatibility/Accuracy 共六项
全部 PASS；6 aggregate PASS、6 config complete、0 runtime Fatal。每个配置使用
`GLOBAL_HEADS=4`、`ROWS_PER_HEAD=2`，检查实际 B2+B3 arithmetic、C model 和 release
join。原始日志：
`artifacts/b4_realip_final_20260912_210500/xsim/vivado.log`。

可复现命令：

```powershell
tests/run_cats_r4_b4_realip_vivado.ps1 `
  -OutputRoot <fresh-output-root> -SkipOoc
```

## Vivado 2025.2 OOC implementation

可复现命令：

```powershell
tests/run_cats_r4_b4_realip_vivado.ps1 `
  -OutputRoot <fresh-output-root> -SkipXsim -ClockPeriodNs 6.666
```

- top：`cats_r4_b4_softmax_pv_cluster`
- device：`xczu15eg-ffvb1156-2-i`
- clock：`6.666 ns / 150.015 MHz`
- synthesis：Complete；synthesis WNS=`-0.164 ns`，未隐藏该负值
- routed setup：WNS=`+0.594 ns`、TNS=`0.000 ns`、0 failing endpoints
- route final estimate：WHS=`+0.010 ns`、THS=`0.000 ns`
- worst setup data path：`5.736 ns`（logic `0.603 ns`，route `5.133 ns`），终点为
  B3 PV MAC response accumulator enable
- routable/fully-routed nets：`76920/76920`；routing errors=`0`
- DRC：0 errors、11 warnings、32 advisories
- methodology：11 个 `DPIR-2` warnings；异步复位寄存器阻止部分 DSP register merge，
  是后续 PPA 优化项，不是功能或 timing failure
- utilization：30613 total LUT（28037 logic LUT、1232 LUTRAM、1344 SRL）、53033 FF、
  195 DSP、0 RAMB36/RAMB18/URAM
- power：vectorless total `1.437 W`，dynamic `0.724 W`，static `0.713 W`，confidence
  `Medium`；没有 SAIF/VCD，不能称为板级实测 power

OOC 原始证据：`artifacts/b4_realip_ooc_final_20260913_000000/ooc/`，包括 DCP、
utilization、timing、critical path、route status、DRC、power、methodology 和完整日志。
日志中保留一条非致命 host/tool `Common 17-1257 Failed to create directory 'C'`；随后同次
运行明确报告 `Synthesis finished with 0 errors, 0 critical warnings`、完成 place/route
并生成 `CATS_R4_B4_REALIP_OOC_PASS`。该异常未被删除或伪装，但不改变已生成报告和
检查点的完整性。

这是单 cluster B-owned contract wrapper 的 OOC implementation。816 个 input ports 和
2554 个 output ports 因没有 package pin location 被 XDC 明确 false-path；内部
clock-to-clock 路径仍按 150 MHz 计时，`unconstrained_internal_endpoints=0`。因此本结果
不是 C/board top 的 I/O 或整板时序签核，也不外推 2/4 cluster 的实现资源。

## II 与限制

- B2 score/exp 的已签核连续流目标保持 II=1；本 B4 修复移除了 reciprocal/output
  backpressure 到 FP32 add data path 的无效依赖。
- B3 Floating Point Operator 配置 `C_Rate=1`；跨 12 个 active contexts 交织并由 RAW
  scoreboard 管理。短行、feedback、bank/FIFO 和 output backpressure stall 仍会被计数，
  不把单行 cycles/issue 写成系统级恒定 II=1。
- 1/2/4 cluster 回归证明相同 workload 的数学顺序和 aggregate 工作量不随实例数翻倍，
  不等于公共 cluster shell 或 board top 已完成。

## A/C/队长集成项

`rtl/core/cluster/cats_r4_cluster_shell.sv` 仍是只允许 `CLUSTERS=1` 的 contract/elaboration
stub，不实现 A/B 算术或 C 存储；B 未越权修改它。系统解除 `NOT READY` 前还需要：

1. C 将 production V3 `weight_wr -> row_commit -> pv_row -> weight_rd ->
   weight_release` service 与实际 V service 接入本 wrapper，并复跑相同回归；
2. A 将 `final_release` 完整 token 接回 score-slot lifecycle，仅在握手后复用 slot；
3. A/C/队长接入 1/2/4 cluster scheduler、output reorder 和 board top，完成真实 I/O、
   DMA/CDC、整板 timing/power 和正式系统数值签核；
4. A/队长对分支中 `a26cdc5ee64e12884fc9e529213ba6630202356b` 的 abort/cancel
   窄修复给出独立 accepted 结论。

结论：B-owned B4 wrapper、修复、TB、1/2/4-cluster 回归和单 cluster OOC 证据已达到
独立 `B-integration-fix` commit 门槛；production C/A/board 集成仍为明确外部阻塞，
不得把本交付称为整板 READY、实际 PPA 或 bit-exact。
