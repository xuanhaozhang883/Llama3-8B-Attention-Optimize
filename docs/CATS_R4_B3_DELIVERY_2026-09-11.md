# CATS-R4 B3 成员 B 交付记录（2026-09-11）

## 状态与代码身份

- 阶段：`B3 32-lane PV / RAW scoreboard / row-end normalize`。
- 状态：`B-OWNED GATES PASS / READY TO COMMIT`；尚未进入 B4，尚未接公共或 board top。
- 分支：`member-b-cats-r4-a2-integration`。
- 测试起点 HEAD：`a26cdc5ee64e12884fc9e529213ba6630202356b`。
- 接口基线：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
  (`CATS_R4_INTERFACE_V3_COMMIT`)。
- V3 已消费。B3 使用 V3 冻结的“单 Q head × 32 features”，没有沿用旧提示中的
  “4 heads × 8 features”。
- A 的 abort/cancel commit 仍由 A/队长独立接收；不影响本记录的 B-owned 单元门禁结论。

本记录中的 OOC 面积/时序和 vectorless 功耗均为综合后估计，不是 place/route 后 PPA、
板上实测或 bit-exact 声明。artifacts 是本地原始证据，不纳入 B-pv 源码提交。

## B-owned 文件

- `rtl/core/bc/pv/cats_r4_b3_pv_controller.sv`
- `rtl/core/bc/pv/cats_r4_b3_pv_mac_32lane.sv`
- `rtl/core/bc/pv/cats_r4_b3_pv_normalize_32lane.sv`
- `rtl/core/bc/pv/cats_r4_b3_pv_32lane.sv`
- `tb/tb_cats_r4_b3_fp32_mocks.sv`
- `tb/tb_cats_r4_b3_pv_controller.sv`
- `tb/tb_cats_r4_b3_pv_arithmetic.sv`
- `tb/tb_cats_r4_b3_pv_32lane.sv`
- `tb/tb_cats_r4_b3_pv_full_workload.sv`
- `tests/run_cats_r4_b3_pv_controller_iverilog.ps1`
- `tests/run_cats_r4_b3_pv_arithmetic_iverilog.ps1`
- `tests/run_cats_r4_b3_pv_32lane_iverilog.ps1`
- `tests/run_cats_r4_b3_pv_full_workload_iverilog.ps1`
- `tests/run_cats_r4_b3_pv_realip_vivado.ps1`

未修改 A 的 QK/scheduler/cluster 控制、C 的 AXI/DMA/CDC/board top 或 D 的 golden、
阈值和原始日志。`fp32_mul_ip`、`fp32_add_ip`、`fp32_to_bf16` 仅作为既有算术封装读取。

关键 RTL SHA-256：

| 文件 | SHA-256 |
|---|---|
| `cats_r4_b3_pv_controller.sv` | `D77BB5D44F8EE000A83BB5C9F21D163A3753639BCEBA0DC8BDE09C25378E7108` |
| `cats_r4_b3_pv_mac_32lane.sv` | `0645FCF6FCE259165B269E0B4413C13EF8995D16B518A858554D738807E8C030` |
| `cats_r4_b3_pv_normalize_32lane.sv` | `CB1022EDF8DF7D388E79111188B16B97D994206E2C9AF501939FBDFF819EAA45` |
| `cats_r4_b3_pv_32lane.sv` | `46535EC3291EE3C82B01DFB222F7CF03F852772E1C774F8AD2D7CB33FAE6BCCF` |

## 冻结实现

1. 三个 V3 weight slot 各映射四个 32-feature block，形成 12 个活动 RAW context；
   context tag 保留 16 个编码。每个 scalar weight 只读一次，再广播到四次 V vector 请求。
2. 每 lane 对每个输出元素严格按 key 递增执行 FP32 multiply、再执行独立 FP32 add；
   未使用 FMA、部分和树或跨 key 重排。
3. Compatibility weight 从 32-bit payload 低 16 位解释为 BF16；Accuracy weight 直接解释
   为 IEEE binary32。V 为 BF16，accumulator 为 FP32。
4. 只有该行最后一个 key 的 32-lane numerator 完成后才进入 `numerator * inv_sum`，随后
   BF16 RNE；四个 feature block 按 0..3 输出，共 128 个 Context word/row。
5. controller 对 weight、V、MAC、normalize 分别保留 owner/tag/key 状态。`clear` 同时清
   metadata、scoreboard 和真实 Floating Point Operator pipeline，旧 completion 不会获得
   新 epoch 的 metadata。
6. 最后一个 Context block 完成 accepted transfer、且 weight/V/MAC/normalize outstanding
   全部清零后，才发布且仅发布一次 `weight_release`。
7. `valid=1 && ready=0` 时 row、weight request、V request、Context output 和 release payload
   均保持稳定；错误计数和 sticky flag 不被正常反压触发。

## 数值范围与参考结果

B3 沿用已冻结且未修改的 B2 数值模型，其中 `accuracy_context_fixed` 明确执行 key-order
FP32 PV、FP32 reciprocal multiply 和 BF16 RNE，因此可作为 B3 独立数学/项目语义对照：

- Accuracy stress：seed `20260905`，32 cases、4096 elements，
  `combined_failures=0`。
- Accuracy stored full：4096 rows、264192 个有效 weight、524288 个 Context element，
  `combined_failures=0`。
- full 最坏绝对误差 `0.0001220703125`，实际/期望 `0xBC8B/0xBC8A`，BF16 distance=1，
  位置 head=4,row=1,feature=84。
- 以上 combined gate 使用未修改的 `abs<=1e-4 OR BF16 distance<=1`；不是 bit-exact。
- Compatibility 的正式 full 软件候选为 `combined_failures=0`；历史合成 stress 中旧
  Q15 row 路径 `459/4096` 仍原样保留，未伪装为通过或放宽阈值。

参考输入 SHA-256：Q
`FA0BABE93C17EE2E9FC22336EC56FD78CA126E1B2307076E649765E6F6A6A810`，K
`76350D5E8C19687CBBF012DF93FF6913621F0601AC74DA9937BE2CCE317A2881`，V
`8C68D4EE9620E1DB71D1733D5A199CA824439C7F2BAA5A1DF8735B22D8480468`，sin
`C98A462FA05FC69845ACBE8B6175A1EC854AC91E1FB5B4A33E2AA7F84271FC5D`，cos
`D30190CD0886513845147A77BAAC3A3453598A617E86F580F1AB25234DB5BD3D`。

历史 full/stress 报告 SHA-256 分别为
`1FE8CC632C0CEF75D735CE9CD5F89778E1B5CF11D15F7A030555B04DC8D3DC86` 和
`85BD41563851EB98B743607A0078C639C97C4A708F5EF6AD2354D602E88FC60A`。

## 协议、压力和完整工作量

可复现命令：

```powershell
tests/run_cats_r4_b3_pv_controller_iverilog.ps1 -Seeds 7,19,73,101,313
tests/run_cats_r4_b3_pv_arithmetic_iverilog.ps1
tests/run_cats_r4_b3_pv_32lane_iverilog.ps1
tests/run_cats_r4_b3_pv_full_workload_iverilog.ps1
```

结果：五个 seed 全 PASS；算术直接 TB PASS；32-lane 端到端 PASS。协议压力覆盖三槽、
variable V latency、weight/V 不同步、随机 row/weight/V/output/release backpressure、
payload stability、中途 clear、旧 epoch completion、slot 重用和 counter clear。

完整 causal workload PASS：

| counter | 实际值 |
|---|---:|
| rows accepted / released | 4096 / 4096 |
| weight request / response / consume | 264192 / 264192 / 264192 |
| V request / response / consume | 1056768 / 1056768 / 1056768 |
| PV MAC issue / result / commit | 33816576 / 33816576 / 33816576 |
| Context words | 524288 |
| output stall cycles | 5869 |
| protocol / numeric / epoch-drop error | 0 / 0 / 0 |

Icarus 原始日志：`artifacts/b3_iverilog_final_20260911_231500/`。

## Vivado 2025.2 真实 IP XSim

命令：

```powershell
tests/run_cats_r4_b3_pv_realip_vivado.ps1 `
  -OutputRoot artifacts/b3_realip_xsim_current_20260911_231000 `
  -SkipOoc `
  -ExistingIpProject <generated-b3-ip-project>
```

当前 RTL 的真实 Floating Point Operator XSim PASS：row=3、weight=4、V vectors=16、
PV MAC=512、Context words=128、cycles=148、RAW stalls=108、全部 error=0。证据：
`artifacts/b3_realip_xsim_current_20260911_231000/xsim/vivado.log`。

实际 XCI 属性：两个 multiply latency=9、adder latency=12；三者 `C_Rate=1`、
`Flow_Control=Blocking`，A/B/RESULT 均有 ready。operator 稳态 II=1 已由生成属性确认，
wrapper 以 12 个活动 context 遮蔽 RAW；短行和反压仍会产生已计数的 RAW/FIFO stall。
当前没有把单行 `cycles/issue` 冒充长流稳态 II，也没有声称系统级始终每周期发射。

## Vivado 2025.2 OOC / PPA 口径

最终命令：

```powershell
tests/run_cats_r4_b3_pv_realip_vivado.ps1 `
  -OutputRoot artifacts/b3_realip_ooc_final_20260911_232000 `
  -SkipXsim `
  -ExistingIpProject <generated-b3-ip-project> `
  -ClockPeriodNs 6.666
```

- tool：Vivado `v2025.2` build `6299465`；part：`xczu15eg-ffvb1156-2-i`。
- top：`cats_r4_b3_pv_32lane`；OOC `synth_design` Complete。
- clock：6.666 ns / 150.015 MHz；WNS=`+3.057 ns`，TNS=`0.000 ns`，failing
  endpoints=0；unconstrained internal endpoints=0，所有输入/输出 delay 已覆盖。
- 最坏 data path delay=`3.500 ns`（logic `0.832 ns`、route estimate `2.668 ns`）。
- Total LUT=`22810`，其中 Logic LUT=`20228`、LUTRAM=`1238`、SRL=`1344`；
  FF=`39714`；DSP=`192`；BRAM36/18=`0/0`；URAM=`0`。
- methodology `Checks found: 0`。batch console 只有 OOC/HD.CLK_SRC 普通提示，
  synthesis 为 0 error / 0 critical warning。
- vectorless power：Total On-Chip=`1.470 W`、Dynamic=`0.757 W`、Device Static=`0.713 W`，
  confidence=`Medium`；`Simulation Activity File=---`。该数字不可替代 SAIF/VCD 或板上功耗。

最终证据目录：`artifacts/b3_realip_ooc_final_20260911_232000/ooc/`，包含 DCP、XDC、
`utilization.rpt`、`timing_summary.rpt`、`methodology.rpt`、`power.rpt` 和 `vivado.log`。
Vivado 2025.2 在包含中文字符的 batch current-directory 下曾以 `-1073740940` 崩溃；
脚本现将全部 Vivado OOC 临时工作放在 ASCII-only `%TEMP%`，完成后再复制证据回 workspace。

## 退出结论与后续边界

B3 的数值模型、直接 TB、五 seed 协议压力、完整 4096 行工作量、当前 RTL 真实 IP XSim、
OOC WNS/PPA 和 `git diff --check` 门禁均已完成，B-owned B3 可标 `READY` 并作为独立
`B-pv` commit 提交。进入 B4 前仍需 A/C 提供真实 C weight service、实际 V service、
cluster wrapper 与 1/2/4 cluster 集成点；B 不自行修改公共 top 或 board top。
