# CATS-R4 B2 成员 B 交付记录（2026-09-07）

> 本文件保留同步前的历史 checkpoint。2026-09-08 的 JSON/v3 消费与最新状态见
> `CATS_R4_B2_DELIVERY_2026-09-08.md`。

## 结论

阶段：`B2 整行 Softmax`

状态：`BLOCKED / NOT READY`

本轮建立了明确分离的 Compatibility/Accuracy 软件数值语义、独立数学参考、
full causal 工作量闭合模型，以及一个 B-owned、未接 production manifest 的
Compatibility 整行 RTL 原型。直接 Python/RTL 测试、仓库权威 full 数据的
whole-row Compatibility 软件评估与既有 v3.1.4 系统回归通过。

本轮不能标 READY：正式 full/stress candidate JSON 缺失；Accuracy exp/sum/
reciprocal RTL 尚未实现；A→B row score/max 和 Accuracy 32-bit weight 生命周期
尚未冻结；本机当前找不到 Vivado/Vitis 2025.2，不能生成 XSim/OOC/PPA/WNS
证据。按照提交条件，不创建 `B-softmax` 伪完成 commit，也不进入 B3。

## Git 身份

- clone root / `FPT_WORKSPACE`：当前仓库根目录；所有代码均相对根目录寻址。
- 分支：`member-b-cats-r4`
- base：`35397958107bb552453bf81858bc25847a8dcffd`
- HEAD：仍为 base；本轮是未提交的 B2 checkpoint。
- interface tag：`CATS_R4_INTERFACE_COMMIT -> 5a4baa5`
- production manifest：未修改；新 RTL 未接公共 top、board top 或 manifest。

## 数值模式与实际运算边界

### Compatibility

- BF16 score/max → signed Q10.14，沿用项目 RTL 饱和/舍入；
- Q1.15 exp ROM，地址为 `round(delta*64)`；`delta>8` 才清零；
- Q15 exp RNE 为 BF16 weight；原始 Q15 exp 按 key 顺序形成 23-bit sum；
- reciprocal=`floor(2^45/sum_q15)`，再按项目 `q30_to_fp32` 转换；
- 这是项目 RTL 语义，不是独立数学语义。

### Accuracy 软件候选

- BF16 score 输入；FP32 weight；逐 key FP32 sum；FP32 reciprocal；
- 不继承 `delta>8` 截断；
- unmasked NaN 为 numeric error；+Inf winner 等权；全 -Inf 合法项等权；
- 当前 host `exp` 后显式舍入 FP32，只是数值边界候选，不是硬件 exp 证明。

模式只能由显式配置选择，不读取文件名、hash、head/row/key、seed 或测试身份。
既有误差规则未修改；combined Gate 通过不写成 bit-exact。

## 输入与参考 hash

| 文件 | SHA-256 |
|---|---|
| `mem/exp_lut_q15.mem` | `27DF1F7633E03E2693164FA8997452118A2AB7B367BFA86618C9E0605E2D317D` |
| `mem/sin_bf16.hex` | `C98A462FA05FC69845ACBE8B6175A1EC854AC91E1FB5B4A33E2AA7F84271FC5D` |
| `mem/cos_bf16.hex` | `D30190CD0886513845147A77BAAC3A3453598A617E86F580F1AB25234DB5BD3D` |
| `vitis/data/q_before_rope_bf16.hex` | `FA0BABE93C17EE2E9FC22336EC56FD78CA126E1B2307076E649765E6F6A6A810` |
| `vitis/data/k_before_rope_bf16.hex` | `76350D5E8C19687CBBF012DF93FF6913621F0601AC74DA9937BE2CCE317A2881` |
| `vitis/data/v_bf16.hex` | `8C68D4EE9620E1DB71D1733D5A199CA824439C7F2BAA5A1DF8735B22D8480468` |
| `vitis/data/attn_out_per_head_bf16.hex` | `1DDEDBB1EB2870D471D6C66505D220EAC4DF2E44423E3529DAD21020BCD4E729` |
| v3.1.4 full-GQA report | `16B7A9C62974B31FA22CB0CB8762756F9401B43F3DC6E37F87846737EFA476DB` |
| B2 whole-row Compatibility full diagnostic report | `04888697EA9A4257B4C40037035219D5F584E29CDF47142F407D7EFC48815EBC` |
| B2 full diagnostic with counter/worst-element evidence | `0E63F93BE97AE5C0AB45CF2824A8BBB1EFA4ED5D97974488F016E3EBF9B69CB7` |

缺失且无 hash：

```text
architecture_study_20260905/row_candidates_full.json
architecture_study_20260905/row_candidates_stress.json
```

全仓、全部 Git 历史和随附 `03_work_v314_causal_bypass.zip` 均未找到它们。

## 修改文件

- `python/cats_r4_b2_row_model.py`
- `rtl/core/bc/softmax/cats_r4_row_softmax_compatibility.sv`
- `tb/tb_cats_r4_row_softmax_compatibility.sv`
- `tb/tb_cats_r4_row_softmax_compatibility_numeric.sv`
- `tests/test_cats_r4_b2_row_model.py`
- `tests/run_cats_r4_b2_softmax.ps1`
- `scripts/cats_r4_b2_softmax_ooc.tcl`
- `docs/CATS_R4_B2_NUMERIC_INTERFACE_CONTRACT.md`
- `docs/CATS_R4_B2_INTEGRATION_REQUEST.md`
- 本文件。

没有修改 A/C/D owned 文件、golden、阈值、原始日志、公共 top 或生产 manifest。

## 测试命令与结果

### B2 直接模型与 RTL

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\run_cats_r4_b2_softmax.ps1 -DiagnosticCases 256
```

结果：`PASS`。Icarus 报告既有 `constant selects in always_*` 能力提示，不是
编译错误。

- Python 单测：6 项 PASS；
- 正式 candidate 输入 preflight：按预期 `BLOCKED`；
- diagnostic seed：`0xB200C0DE`；随机 256 + 定向 6 行；
- Compatibility vs independent math：16,736 elements，different=14,446，
  strict_abs_failures=171，combined_failures=80，max_abs_error=0.00390625；
- Accuracy software candidate vs independent math：16,736 elements，
  different=0，strict/combined failures=0；
- RTL interleave/backpressure：rows=2，exp/weight/sum commit=6，
  reciprocal commit=2，output stall=22，reciprocal stall=52，errors=0；
- RTL numeric：后部最大值、delta=1、delta=9 cutoff 通过；sum=44,823，
  reciprocal_q30=784,962,454，连续 3 个 exp issue 的实测 II=1；
- clear/epoch：clear 后 counter/state 清零，context tag 0 在 epoch 3 重用通过。

Compatibility diagnostic 的 80 个 combined failures 必须保留。它不是提示词所述
旧 stress 文件的 `459/4096` 复现，二者不能混写。Accuracy 的 0 failures 只属于
软件候选 diagnostic，不能写成 Accuracy RTL 或正式 full/stress PASS。

### 仓库权威 full 数据的 whole-row Compatibility 软件评估

```powershell
python .\python\cats_r4_b2_row_model.py --authoritative-full-diagnostic `
  --json "$env:TEMP\cats_r4_b2_authoritative_full.json"
```

该入口调用项目 `baseline_v30`；它正是全局 row max、Q15 exp、BF16 probability、
floor reciprocal 和 key-ordered PV 的 whole-row Compatibility 软件路径。实际结果：
4,096 rows、524,288 elements、combined_failures=0、different=225,853、
strict_abs_failures=7、max_abs_error=0.0001220703125。该结果复核了仓库权威 full
数据上的软件候选，但不是缺失的 `row_candidates_full.json`，也不是 RTL/XSim/
OOC/board 证明；因此仍不解除正式 full/stress Gate。

最坏 absolute-error 元素：head=12、row=2、feature=8，actual=`0xBC85`
（-0.0162353515625），expected=`0xBC84`（-0.01611328125），absolute error=
0.0001220703125、BF16 ULP distance=1，因此不构成 combined failure。软件
issue/result/commit 实际闭合 row=4,096、exp/weight/sum=264,192、
reciprocal=4,096。

### 既有 v3.1.4 系统回归

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\run_v313_qk4_system_checks.ps1
```

结果：`PASS`。覆盖 QK lanes 1/2/4/8、causal skip、随机 backpressure、consumer/
full integration 和 full-GQA 数值模型。full-GQA 为 4,096 rows、524,288 elements，
combined_failures=0、different=223,988、strict_abs_failures=3、
max_abs_error=0.0001220703125。该结果证明 fallback 无回归，不证明新 B2 已集成。

## Counter 与 II

模型推导的完整 causal 目标：

| Counter | issue | result | commit |
|---|---:|---:|---:|
| row | 4,096 | 4,096 | 4,096 |
| exp | 264,192 | 264,192 | 264,192 |
| weight | 264,192 | 264,192 | 264,192 |
| sum | 264,192 | 264,192 | 264,192 |
| reciprocal | 4,096 | 4,096 | 4,096 |

这些是经过模型 invariant 检查的目标，不是 full-size RTL 实测 counter。当前直接
RTL 仅闭合小规模 2-row/6-exp 与 1-row/3-exp 场景。Compatibility exp 在无输出
stall 的连续输入定向测试中 II=1；random backpressure 下 stall 可解释。Accuracy
RTL II 尚无数据。

## XSim / OOC / PPA / WNS

- 已提供 `scripts/cats_r4_b2_softmax_ooc.tcl`，目标 part 和 150 MHz 约束明确；
- 当前所有已挂载文件系统均未找到 Vivado/Vitis 2025.2 executable；
- 因此 XSim、OOC synthesis Complete、LUT/FF/BRAM/DSP/URAM、WNS/TNS 均为
  `BLOCKED / NOT MEASURED`；
- 不引用 v3.1.4 PPA 作为本候选结果，也不使用 PATH 中旧 Vivado 2018.3。

## 阻塞与最小恢复入口

1. D/队长提供两个原始 candidate JSON 及来源 hash；B 审计 schema 后接入正式
   full/stress Gate，保留全部失败 seed。
2. A/队长处理 `IR-B2-001/002/003`：冻结 row score/max、completion，并决定
   Accuracy FP32 weight 使用 B-local store 还是发布新的公共 interface version。
3. 获得接口决定后实现 Accuracy 范围缩减+插值/多项式 exp、FP32 key-ordered sum
   和 reciprocal RTL；任何 Accuracy failure 立即 STOP 定位，不放宽阈值。
4. 提供/恢复 Vivado 2025.2 后，在全新短 ASCII root 执行 XSim/OOC，报告真实
   latency/rate/II、PPA/WNS 和综合属性。
5. 完成正式 full/stress/random/backpressure/reset、直接单测、系统集成回归、
   `git diff --check`、OOC Gate 后，才允许创建独立 `B-softmax` commit。

请求：A/队长冻结接口选择；D/队长补齐两份 candidate JSON；工具环境负责人提供
Vivado 2025.2。当前不请求 C 接 board/system top，也不进入 B3。
