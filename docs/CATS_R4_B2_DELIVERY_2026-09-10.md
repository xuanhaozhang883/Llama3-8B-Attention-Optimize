# CATS-R4 B2 成员 B 交付记录（2026-09-10）

## 结论

- 阶段：`B2 整行 Softmax`。
- 状态：`WHOLE-ROW RTL CHECKPOINT / NOT READY`。
- 分支：`member-b-cats-r4-a2-integration`。
- A2 base：`d06d999a409a68dd89d1e4db8d78d3eb8f5574cb`。
- HEAD：`a26cdc5ee64e12884fc9e529213ba6630202356b`。
- 已消费 `CATS_R4_INTERFACE_V3_COMMIT`：
  `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`。
- 本轮没有修改 A/C/D 文件，没有提交、推送或进入 B3。

方案 A 整行 staging、Compatibility V3 wrapper 和 A2→B2 Compatibility 回归保持
PASS。本轮增加 Accuracy 的 bit-oriented 软件镜像、三个算术单元、三槽整行 row core，
并按队长冻结决定完成 Compatibility/Accuracy finalize 前仲裁、单一三槽 shared
stager 的本地 B wrapper。定向错误隔离、完整数据形状、存储 Q/K 派生的 264192 个
score、实际 A serializer 接入及 shared-wrapper 回归均通过 Icarus；这些仍不是
XSim/OOC 或板级证据，因此不能写成 B2 完成。

## 新增 B 文件

- `python/cats_r4_b2_accuracy_fixed_model.py`
- `tests/test_cats_r4_b2_accuracy_fixed_model.py`
- `rtl/core/bc/softmax/cats_r4_accuracy_exp_fixed.sv`
- `rtl/core/bc/softmax/cats_r4_fp32_positive_add.sv`
- `rtl/core/bc/softmax/cats_r4_fp32_row_reciprocal.sv`
- `rtl/core/bc/softmax/cats_r4_row_softmax_accuracy.sv`
- `rtl/core/bc/softmax/cats_r4_b2_accuracy_v3_wrapper.sv`
- `rtl/core/bc/softmax/cats_r4_b2_compatibility_core_adapter.sv`
- `rtl/core/bc/softmax/cats_r4_b2_locking_arbiter.sv`
- `rtl/core/bc/softmax/cats_r4_b2_shared_stager_v3_wrapper.sv`
- `tb/tb_cats_r4_accuracy_exp_fixed.sv`
- `tb/tb_cats_r4_fp32_positive_add.sv`
- `tb/tb_cats_r4_fp32_row_reciprocal.sv`
- `tb/tb_cats_r4_row_softmax_accuracy.sv`
- `tb/tb_cats_r4_b2_accuracy_v3_wrapper.sv`
- `tb/tb_cats_r4_b2_accuracy_v3_full.sv`
- `tb/tb_cats_r4_b2_locking_arbiter.sv`
- `tb/tb_cats_r4_b2_shared_stager_v3_wrapper.sv`
- `tb/tb_cats_r4_row_softmax_accuracy_interleave.sv`
- `tests/run_cats_r4_b2_accuracy_fixed_model.ps1`
- `tests/run_cats_r4_b2_accuracy_exp_iverilog.ps1`
- `tests/run_cats_r4_b2_fp32_positive_add_iverilog.ps1`
- `tests/run_cats_r4_b2_fp32_reciprocal_iverilog.ps1`
- `tests/run_cats_r4_b2_accuracy_v3_iverilog.ps1`
- `tests/run_cats_r4_b2_accuracy_v3_full_iverilog.ps1`
- `tests/run_cats_r4_b2_accuracy_v3_stored_full_iverilog.ps1`
- `tests/run_cats_r4_b2_accuracy_interleave_iverilog.ps1`
- `tests/run_cats_r4_a2_b2_accuracy_iverilog.ps1`
- `tests/run_cats_r4_a2_b2_shared_iverilog.ps1`
- `tests/run_cats_r4_b2_shared_accuracy_full_iverilog.ps1`
- `tests/run_cats_r4_b2_shared_compatibility_full_iverilog.ps1`
- `tests/run_cats_r4_b2_shared_stager_v3_iverilog.ps1`

`tb/tb_cats_r4_a2_b2_compatibility_integration.sv` 增加编译期开关，以同一组 A serializer
激励分别回归 Compatibility/Accuracy；默认 Compatibility 路径和原命令保持不变。

## 数值边界

Accuracy exp 不继承 Compatibility 的 `max-score>8` 截断。当前候选固定为：

1. BF16 RNE 后的 row max 和 score 转成有符号 Q16，`max-score` 饱和到 104；
2. 使用 Q16 常量 `log2(e)=94548/65536` 做范围缩减；
3. 小数部分采用 32 段、33 项 Q31 `2^(-x)` LUT 和 Q11 线性插值；
4. 最终按 RNE 编码为 FP32 weight，包含正常数、次正规数和零；
5. 非有限 max/score 或 `score>row_max` 产生 numeric error 和零 weight。

row sum 使用只接受非负有限输入的 FP32 RNE adder，严格按 key 顺序反馈。reciprocal
只接受 B2 已证明的 `1.0<=sum<=128.0` 正常 FP32 域，以 `2^47/significand` 的 48-cycle
整数除法及 ties-to-even 舍入生成 FP32 `1/sum`。越界、负数和非有限输入明确报错。

软件 full/stress 仍用相同的 BF16 I/O、key-order FP32 sum/PV 和项目 combined 规则；
它是 operator candidate，不是 RTL full-system、XSim、OOC 或硬件结果。

当前源码 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `python/cats_r4_b2_accuracy_fixed_model.py` | `90C0C936DC7EA0F72806101E786622DE50F88F377A97C9B390FBDA80E5BC325B` |
| `rtl/core/bc/softmax/cats_r4_accuracy_exp_fixed.sv` | `462C4BA56A3CFDA4CD5B60A46B08629D7A946ED84992AB9A71848071935C8CD0` |
| `rtl/core/bc/softmax/cats_r4_fp32_positive_add.sv` | `2D56F4FD70374B51C20750BEF968606155847B751CD3E6F63456AB0FE45F534F` |
| `rtl/core/bc/softmax/cats_r4_fp32_row_reciprocal.sv` | `31E07730DF5906E87000D60B8A4148A9C57529B839405F58FE2716338208B517` |
| `rtl/core/bc/softmax/cats_r4_row_softmax_accuracy.sv` | `B7D1F82B457D369CAE7F878A5B606909A36FB4992D5E932315E3CFB293F26C34` |
| `rtl/core/bc/softmax/cats_r4_b2_accuracy_v3_wrapper.sv` | `E5D15BBB022B5E1FD8BCBD82AF29EE153EEF83DA67F1F348287A8F2C889C81A6` |
| `rtl/core/bc/softmax/cats_r4_b2_compatibility_core_adapter.sv` | `52CAA82761E6FB15B776033142CDF0E4B557F489EDD8C1AE990B72E450BB71A0` |
| `rtl/core/bc/softmax/cats_r4_b2_locking_arbiter.sv` | `513CC6BC53583FB947F68B802BF1441BE67B798F63D79E50ECB4297DF8F1F021` |
| `rtl/core/bc/softmax/cats_r4_b2_shared_stager_v3_wrapper.sv` | `99DEDE5234391F3EBEF92D9841874100C4D64E7B0F5ECCC9BBAB01C007D954EA` |
| `rtl/core/bc/softmax/cats_r4_b2_weight_stager.sv` | `F69825C98759FDA1357E89D87130CC1B6FA2E167CBA2066AECFE8386AD96891F` |

## 软件数值回归

命令：

```powershell
tests/run_cats_r4_b2_accuracy_fixed_model.ps1
python python/cats_r4_b2_accuracy_fixed_model.py --stress
python python/cats_r4_b2_accuracy_fixed_model.py --full
```

结果：

- stress：seed `20260905`，32 cases，4096 elements，`combined_failures=0`；
  2976 次 exp/weight/sum 和 32 次 reciprocal 全部闭合。
- full stored vectors：4096 rows、264192 次 exp/weight/sum、4096 次 reciprocal、
  524288 Context elements，`combined_failures=0`。
- full 最坏绝对误差 `0.0001220703125`，实际/期望为 `0xBC8B/0xBC8A`，
  BF16 distance=1，位置 head=4,row=1,feature=84。
- exp 网格覆盖 `[-104,0]` 的 BF16 输入，单调且正常数区最大相对误差
  `<5e-4`；`exp(-103)` 为最小 FP32 次正规数，`exp(-104)` 为零。

`combined_failures=0` 不表示 bit-exact；full 中 different=208884、strict_abs_failures=18、
over_one_ulp=59927。高 ULP 项位于接近零的区域，combined 由项目冻结的
`abs<=1e-4 OR BF16 distance<=1` 判定，未修改阈值。

## 独立 RTL/模型逐位回归

```powershell
tests/run_cats_r4_b2_accuracy_exp_iverilog.ps1
tests/run_cats_r4_b2_fp32_positive_add_iverilog.ps1
tests/run_cats_r4_b2_fp32_reciprocal_iverilog.ps1
```

- exp：8192 vectors 全部逐位匹配；5 个非法 special/order vectors；
  1310 output stall cycles；issue=result=commit=8192。
- positive FP32 add：8192 vectors 全部逐位匹配；6 个非法 vectors；
  803 output stall cycles；issue=result=commit=8192。
- reciprocal：8192 vectors 全部逐位匹配；6 个非法/越界 vectors；
  417430 busy stall cycles、8175 output stall cycles；
  issue=result=commit=8192。
- 三项都覆盖 clear 丢弃在途状态、metadata 保序以及 valid=1/ready=0 时 payload 稳定。

exp 和 add 为一项 elastic pipeline，无输出反压时接口结构支持每周期接受一项；add
允许前一结果提交与下一操作同周期接受，适合严格 key-order feedback。reciprocal 固定
48-cycle，每行只发一次；是否在实际整行调度下形成瓶颈，必须由后续 Accuracy wrapper
counter 和 OOC 结果证明，当前不虚构系统 II。

## Accuracy 整行 RTL 与实际 A 接入

```powershell
tests/run_cats_r4_b2_accuracy_v3_iverilog.ps1
tests/run_cats_r4_b2_accuracy_v3_full_iverilog.ps1
tests/run_cats_r4_b2_accuracy_v3_stored_full_iverilog.ps1
tests/run_cats_r4_b2_accuracy_interleave_iverilog.ps1
tests/run_cats_r4_a2_b2_accuracy_iverilog.ps1
```

- 三槽定向 row core：5 rows、10 weights；wrong-last 与 Inf 行被隔离；
  protocol=1、numeric=3，PASS。
- V3 scheme-A 定向 wrapper：3 个合法行产生 384 writes/3 commits，2 个错误行对 C
  零写；5 releases，PASS。
- equal-score 完整数据形状：4096 rows、264192 causal scores、524288 accepted
  writes、4096 commits/releases；全部 error counter=0，随机输出反压 175691 cycles，
  总仿真 1533055 cycles，PASS。
- stored Q/K/RoPE 整行逐位回归：重新派生全部 264192 个 BF16 score；RTL 的每个
  FP32 weight、每行 sum/inv_sum 与 `accuracy_row_fixed` 逐位一致；同样闭合
  4096/264192/524288/4096/4096，全部 error counter=0，PASS。
- actual `cats_r4_qk_ab_handoff`→Accuracy：1 row、4 scores、128 writes、1 commit，
  token/key/last/mode 和随机下游反压全部通过；默认 Compatibility 版本同步复测 PASS。
- 三行交织：3 个 row=127 槽按 slot 0/1/2 轮转输入，384 个 score 在 384 个连续
  cycle 接受，issue span=383，实测 score/exp issue II=1；行末单 reciprocal 产生
  100 busy stalls，exp/sum tail stall=50/100，counter 可解释。测试还在测量前清除一条
  已接收首个 score 的旧 epoch 行，clear 后无旧 weight/done 泄漏，PASS。

stored-row 参考输入 SHA-256：Q `FA0BABE93C17EE2E9FC22336EC56FD78CA126E1B2307076E649765E6F6A6A810`，
K `76350D5E8C19687CBBF012DF93FF6913621F0601AC74DA9937BE2CCE317A2881`，
sin `C98A462FA05FC69845ACBE8B6175A1EC854AC91E1FB5B4A33E2AA7F84271FC5D`，
cos `D30190CD0886513845147A77BAAC3A3453598A617E86F580F1AB25234DB5BD3D`。
运行时向量写入系统临时目录并在回归结束删除，不修改 golden 或原始输入。

完整回归当前 source driver 逐项发送，`input_score_stalls=0`，所以它本身证明数值、
顺序和计数闭合；持续三行用独立交织 TB 证明 II=1 和 reciprocal tail stall。随机
row/score backpressure、随机 reset 多 seed 仍是门禁缺口。Icarus 的 constant-select 与
assertion synthesis 提示是工具能力提示，不能替代 Vivado lint/synthesis 结论。

## 保持通过的方案 A/Compatibility 回归

```powershell
tests/run_cats_r4_b2_weight_stager_iverilog.ps1
tests/run_cats_r4_b2_compatibility_v3_iverilog.ps1
tests/run_cats_r4_a2_b2_compatibility_iverilog.ps1
```

- scheme-A stager：4096 rows、264192 causal weights、524288 accepted writes、
  4096 commits/releases、178181 output stall cycles，PASS。
- Compatibility V3：3 rows、7 exp、384 writes、3 commits/releases，PASS。
- actual A2 serializer→B2 Compatibility：4 scores、128 writes、1 commit，PASS。

## 共享 stager / numeric-mode 本地检查点

队长冻结“一套共享 stager”后，B 新增
`cats_r4_b2_shared_stager_v3_wrapper.sv`，保持 V3 row/score/C-side/release 端口不变：

1. row handshake 时为每个 slot 锁存完整 token 和 `numeric_mode`；后续 score 以 slot
   所有权路由，输入 mode 改变不会重选 arithmetic core。
2. Compatibility/Accuracy 各有独立算术 state；weight 和 finalize 各由一个
   `cats_r4_b2_locking_arbiter` 仲裁。两源同时 valid 时 round-robin 选择一源，若下游
   backpressure 则选择和 payload 保持稳定，禁止双写/覆盖。
3. 仅例化一个 `cats_r4_b2_weight_stager`，保留已冻结的 3x128x32-bit scheme-A
   容量；错误在 publish 前隔离，C 侧零写。
4. `clear` 丢弃所有 owner/在途数据；`counter_clear` 只允许 quiescent wrapper，清
   B-owned counters/sticky。reset 清两者。

```powershell
tests/run_cats_r4_b2_shared_stager_v3_iverilog.ps1
tests/run_cats_r4_a2_b2_shared_iverilog.ps1
tests/run_cats_r4_b2_shared_accuracy_full_iverilog.ps1
tests/run_cats_r4_b2_shared_compatibility_full_iverilog.ps1
```

- locking-arbiter 定向 collision/stall：Compatibility 与 Accuracy 各一次 grant，选中
  源在连续五周期 ready=0 中稳定，PASS。
- shared wrapper 随机 C-side ready：seed 7/19/73 均 PASS。每个 seed 正常两行产生
  256 writes、2 commits、3 releases；故意 mode/token 非法流产生 2 个 mode error、
  4 个 protocol error，错误行零写；随机输出 stall 为 86/88/87 cycles。旧 epoch
  partial row 经 clear 后无泄漏，quiescent `counter_clear` 后所有 B counters/sticky
  均归零。
- actual A serializer→shared wrapper：mode 0 Compatibility 与 mode 1 Accuracy 各
  1 row/4 scores/128 writes/1 commit，全部 error=0，PASS。
- shared Accuracy full：equal-row 和 stored Q/K/RoPE 两套输入各为 4096 rows、
  264192 causal scores、524288 writes、4096 commits/releases；cycles=1533055，
  output stalls=175691，所有 error=0，PASS。stored case 每个 FP32 weight 和
  row sum/inv_sum 对 fixed model 逐位一致。
- shared Compatibility full：independent equal-row metadata hash
  `37103ac832be9a538f508dd99227bd49ed0a97fc6a2d1c4be37873d337a9568e`；4096 rows、
  264192 scores、524288 writes、4096 commits/releases；cycles=1520727，output
  stalls=175651，所有 error=0，PASS。

## 当前缺口与下一步

1. 补随机上游 row/score backpressure、随机 reset 多 seed 和 full/stress 混合 mode
   的系统协议压力；当前已覆盖连续三行 score/exp II=1、busy 期间输入 mode 改变、
   共享 arbitration 定向 stall、C-side 三 seed 随机反压、clear/旧 epoch 和
   quiescent counter clear；
2. 接 C 的实际 weight memory service，并在 B3 最终输出后才产生 final release；
3. A 需审查/接收仅含 abort 生命周期修复的 `a26cdc5ee64e12884fc9e529213ba6630202356b`；
   该 commit 目前仅为待接收，不视为团队基线；
4. 找到 Vivado 2025.2 后运行 XSim、xczu15eg-ffvb1156-2-i OOC，并报告
   utilization、WNS/TNS、关键路径和实际 II；
5. 补 XSim full/stress 及一个接 C 实际 service 的系统级回归。

Vivado 2025.2 已确认可用；OOC 已执行但因负 WNS 失败，XSim、实现后 PPA/TNS 和
正式时序闭合仍 `MISSING / NOT RUN`。C 实际存储、A abort commit 接收、随机上游/系统
协议多 seed 也仍 `MISSING`，因此 B2 结论保持 `NOT READY`，不提交 `B-softmax`
伪完成，也不进入 B3。

## Vivado 2025.2 OOC（2026-09-11，失败 gate）

Vivado `v2025.2` 已在 `xczu15eg-ffvb1156-2-i` 上完成 shared wrapper 的 OOC
`synth_design`，其原始输出位于
`artifacts/b2_shared_ooc_20260911_101421/`。使用 6.666 ns（150 MHz）约束时，
综合资源为 LUT=12071（3.54%）、FF=16267（2.38%）、DSP=3（0.09%）、BRAM/URAM=0；
这是 OOC 综合估计，不是实现后 PPA。

该 run 的时序 gate **失败**：`WNS=-10.915 ns`。最坏路径为
`score_slot_id[0]` 到 `u_accuracy/u_exp/out_weight_reg_reg[10]/D`，data path delay
为 16.571 ns（logic 7.652 ns，route 8.919 ns），因此当前 Accuracy exp 不能满足
150 MHz。Tcl 正确以负 WNS 返回失败；虽然 checkpoint、utilization、timing 和
methodology 报告已生成，但不得将其记录为 OOC PASS 或 B2 READY。

综合还有 17 条 critical warnings（另有 115 条 warnings）；其中应优先处理的
`cats_r4_b2_weight_stager.sv:385` 同优先级 set/reset 提示可能造成仿真/综合不一致。
下一步只能在 B-owned exp 路径加入保持 II=1 的流水边界、复跑单测/full/OOC，并检查
stager reset 语义；未通过前不进入 B3。
