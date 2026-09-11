# CATS-R4 B2 成员 B 交付记录（2026-09-09）

## 结论

- 阶段：`B2 整行 Softmax`。
- 状态：`ARCHITECTURE UNBLOCKED / RTL CHECKPOINT / NOT READY`。
- frozen interface：`CATS_R4_INTERFACE_V3_COMMIT^{commit}` =
  `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`。
- B 集成分支：`member-b-cats-r4-a2-integration`。
- A2 base：`d06d999a409a68dd89d1e4db8d78d3eb8f5574cb`。
- 已提交 HEAD：`a26cdc5ee64e12884fc9e529213ba6630202356b`。
- B2 新文件仍是未提交 checkpoint；未达到 B-softmax 提交门禁，没有提交伪完成，
  没有推送，也没有进入 B3。

## A abort/cancel 独立提交

队长接受 owner=A abort/cancel 状态转移并允许制作 A cherry-pick commit。独立提交：

```text
a26cdc5ee64e12884fc9e529213ba6630202356b
fix(qk): release A-owned slots on row abort
```

diff 严格为 4 个文件：

- `rtl/core/bc/qk/cats_r4_qk_slot_lifecycle.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_handoff_wrapper.sv`
- `tb/tb_cats_r4_qk_slot_lifecycle.sv`
- `tb/tb_cats_r4_qk_row_handoff_wrapper.sv`

实现 owner=A、完整 token 匹配的原子 abort/cancel；stall 时 payload/owner 保持；
同槽 final-score handoff 竞争时 abort 优先；成功 abort counter 每个握手只增加一次；
token 不匹配不释放。提交尚未推送，仍需 A 审查/cherry-pick。

对应回归均 PASS：

```powershell
tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_ab_handoff_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_qk_row_abort_arbiter_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
```

A→B full handoff 保持 rows=4096、causal scores=264192。

## 方案 A 冻结与 RTL checkpoint

队长冻结整行 staging 后发布，不增加 V3 `weight_abort`。B 新增：

- `rtl/core/bc/softmax/cats_r4_b2_weight_stager.sv`
- `rtl/core/bc/softmax/cats_r4_b2_compatibility_v3_wrapper.sv`
- `tb/tb_cats_r4_b2_weight_stager.sv`
- `tb/tb_cats_r4_b2_compatibility_v3_wrapper.sv`
- `tb/tb_cats_r4_a2_b2_compatibility_integration.sv`
- `tests/run_cats_r4_b2_weight_stager_iverilog.ps1`
- `tests/run_cats_r4_b2_compatibility_v3_iverilog.ps1`
- `tests/run_cats_r4_a2_b2_compatibility_iverilog.ps1`

stager 物理声明三份 `128*32-bit` weight scratch，并保存三组 sum/inv_sum 与 token。
算术侧只提供 causal `key=0..row`；stager 检查完整 token、严格 key 顺序、last、模式
payload、weight 非负有限、sum/inv_sum 正且有限。成功 finalize 前不进入 publish；masked
key 由发布器产生 `mask=1,data=+0`；每行固定接受 128 次 `weight_wr` 后才允许一次
`row_commit`。commit 后 slot 保持 HELD，必须等完整 token 的后续 release，不能提前复用。

pre-publish 错误通过 B 本地 `row_error` 报告；错误行对 C 零写且等待 release/clear。
publish 开始后的 mask/last/commit 状态违规是 assertion/fatal，需要全局 clear，不转成
可恢复的 C abort。

Compatibility V3 adapter 消费 A 的完整 row/score token，把旧 Q15→BF16 weight 放在
32-bit payload 低 16 位并将高 16 位清零；`sum_q15/2^15` 精确编码成 FP32，reciprocal
沿用 floor Q30 后的 FP32 语义。该 adapter 明确只接受 mode=0；它不会把 Accuracy 输入
静默按 Compatibility 计算。

## 测试与计数

```powershell
tests/run_cats_r4_b2_weight_stager_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_b2_compatibility_v3_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
tests/run_cats_r4_a2_b2_compatibility_iverilog.ps1 -IcarusRoot D:\iverilog\iverilog
```

结果：

- scheme-A stager：PASS；定向覆盖三槽占满、finalize 前零 C 写、random output
  backpressure、wrong last、旧 epoch、上游 numeric error、NaN/Inf weight/sum、中途
  clear、error payload stall、完整 token release。
- full causal stager：rows=4096、valid staged weights=264192、weight_wr accepted=524288、
  row_commit=4096、release-stub=4096、output stall cycles=178181、所有正常 error=0。
- Compatibility V3 adapter：PASS；3 rows、7 exp、7 staged weights、384 C writes、
  3 commits、3 release-stub；检查 BF16 low16、高16零、masked零、sum/inv 元数据与
  valid/ready stall 稳定。
- 实际 A2 serializer→B2 Compatibility：PASS；1 row header、4 score read/request/
  response/transfer、4 staged weights、128 C writes、1 commit；A/B protocol 与 numeric
  error 均为 0。该 TB 直接实例化 A 的 `cats_r4_qk_ab_handoff.sv`，不是只比较端口表。

这里的 524288 writes 是 B2 stager Icarus 单元闭合，release 是明确的 unit-test stub；
不是 C memory、B3、XSim、OOC、board 或系统集成证明。Icarus 的
`constant selects in always_*` 是工具能力提示，仿真退出码为 0。

本轮 checkpoint SHA-256：

| 文件 | SHA-256 |
|---|---|
| `rtl/core/bc/softmax/cats_r4_b2_weight_stager.sv` | `F69825C98759FDA1357E89D87130CC1B6FA2E167CBA2066AECFE8386AD96891F` |
| `rtl/core/bc/softmax/cats_r4_b2_compatibility_v3_wrapper.sv` | `660A8D4218C8686BFCE4B48BC63BF60F382DE4D3DE800B203FD2F490BDDCCBBC` |
| `tb/tb_cats_r4_b2_weight_stager.sv` | `7B7E44A343205A02925849E9793DB97C88053179F88B5193C6EABCB97B3D7E3F` |
| `tb/tb_cats_r4_b2_compatibility_v3_wrapper.sv` | `05852DF3954B9A19362CC5160FED1D18F256CDB028F5B2F669240A9DD7705D9F` |
| `tb/tb_cats_r4_a2_b2_compatibility_integration.sv` | `E4E765C5E1F3A1D472A092808EEA1EAA9685C2CA673226B995F91B4AB7F37FEB` |

## 数值与证据边界

- Compatibility arithmetic：现有 BF16→Q10.14、Q15 exp LUT、`delta>8` 截断、
  BF16 weight、Q15 key-order sum、floor Q30 reciprocal；直接 RTL/模型回归此前 PASS。
- Accuracy 软件 arithmetic：软件 32-segment range-reduction candidate 已存在，但
  FP32 exp/sum/reciprocal RTL 仍为 `MISSING`。
- full/stress JSON 仍只提供历史聚合软件证据；stress 的旧 row_q15 保持
  `459/4096 failures`，软件 FP32 exp 为 0，不能改写成硬件结果。
- combined gate 通过不得称为 bit-exact。

## II、PPA 与阻塞

- scheme-A publish：无反压时 `weight_wr` 每周期一项，结构目标 II=1；当前 full TB
  含随机反压，未把平均 accepted interval 冒充算术 II。
- Compatibility exp 原型此前定向 no-stall TB 为 issue II=1。
- Accuracy exp II：`MISSING / NOT MEASURED`。
- Vivado 2025.2：本机没有已确认可用路径，XSim/OOC 均 `NOT RUN`。
- utilization、WNS、TNS、关键路径：`MISSING`。
- C 实际 weight memory service、B3 PV/final release、公共 top/system integration：
  `MISSING`。
- 共同 transaction-start/mode wrapper、Accuracy FP32 arithmetic、正式 full/stress
  硬件数值回归：`MISSING`。

因此 B2 保持 `NOT READY`。架构决策阻塞已解除，可以继续 Accuracy 和
共同 wrapper 开发；但在 XSim、OOC、PPA/WNS、正式数值和系统证据齐全前不得提交
`B-softmax` 完成提交。
