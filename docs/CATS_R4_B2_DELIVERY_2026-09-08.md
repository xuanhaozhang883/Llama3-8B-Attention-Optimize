# CATS-R4 B2 成员 B 交付记录（2026-09-08）

## 结论

- 阶段：`B2 整行 Softmax`
- 状态：`BLOCKED / NOT READY`
- 本轮完成：消费 v3 冻结契约；审计恢复的 full/stress JSON；修正统一 weight
  payload 和非有限值语义；完成 Accuracy 范围缩减+LUT 插值的软件候选消融。
- 本轮未完成：Accuracy RTL、v3 B-owned wrapper、XSim/OOC/PPA/WNS。
- 没有修改 A/C/D owned RTL、golden、阈值、原始 JSON、公共 top 或 production
  manifest；没有创建 `B-softmax` 完成提交，也没有进入 B3。

## Git 与接口身份

- 分支：`member-b-cats-r4`
- 同步 base / HEAD：`108e43b4277f3a0c5f0f4db1ad1d41eed119c775`
- 已包含远端协作 tip：`132be51`
- frozen interface：`CATS_R4_INTERFACE_V3_COMMIT^{commit}` =
  `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
- 工作状态：B2 文件均为未提交/未跟踪；当前记录不是硬件 READY commit。

## 恢复报告审计

文件：

- `docs/architecture_study_20260905/row_candidates_full.json`
  SHA-256 `1fe8cc632c0cef75d735ce9cd5f89778e1b5cf11d15f7a030555b04dc8d3dc86`
- `docs/architecture_study_20260905/row_candidates_stress.json`
  SHA-256 `85bd41563851eb98b743607a0078c639c97c4a708f5ef6ad2354d602e88fc60a`

`audit_official_candidate_reports` 验证报告字节身份、schema、32 heads、128 rows、
524,288 full 元素、不可变误差合同和 8 个当前输入 hash。历史 full 的四个软件
候选均为 `combined_failures=0`；历史 stress 原样保留：

| 候选 | elements | combined failures |
|---|---:|---:|
| online_q15 | 4,096 | 482 |
| row_q15 | 4,096 | 459 |
| row_fp32_exp_software | 4,096 | 0 |

JSON 只有聚合软件指标，没有逐行 score/V/output；因此这里只通过产物身份审计，
没有声称当前 RTL 已重放这些报告。

## v3 数值修正

1. Compatibility BF16 weight 放在统一 32-bit payload 的低 16 位，高 16 位为零，
   不再错误地左移到高 16 位。
2. Compatibility 内部 `sum_q15` 精确转换为 binary32 的 `sum_q15/2^15`，供 v3
   `sum_fp32` 使用；内部 floor Q30 reciprocal 语义不变。
3. Accuracy 拒绝任一 unmasked NaN 或 `+/-Inf`，增加 numeric error，不发布
   exp/weight/reciprocal 或正常 row commit。
4. 有限 exp 下溢明确允许产生 binary32 `+0`；旧 `delta>8` 截断只属于
   Compatibility。

独立数学参考与项目语义继续分离。阈值保持
`abs <= 1e-4 OR BF16 ordered distance <= 1`；combined gate 通过不称为 bit-exact。

## Accuracy exp 软件运算候选

边界：BF16 score → FP32 `score-max` → FP32 `-delta*log2(e)` 范围缩减 →
整数指数移位 + `2^-fraction` LUT 线性插值 → FP32 key-ordered sum → FP32
reciprocal。Context 组合测试按 key 顺序分别开 FP32 乘法/加法，行末使用
reciprocal 后乘法，不使用最终直接除法。

网格测试覆盖 `delta=-104..0`、步长 `1/256`；32 段候选单调、不会在 `-9`
截断，在测试的 `-104` 边界舍入为零，normal 结果的最坏相对 exp 误差为
`6.2121996074e-05`。

### 重放 deterministic stress seed 20260905

| LUT segments | entries | different | strict abs failures | combined failures | max abs | max ULP |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 17 | 218 | 119 | 3 | 0.00390625 | 217 |
| 32 | 33 | 69 | 32 | 0 | 0.001953125 | 74 |
| 64 | 65 | 30 | 13 | 0 | 0.001953125 | 10 |
| 128 | 129 | 11 | 2 | 0 | 0.001953125 | 3 |

16 段被拒绝；32 段是 stress 中最小的 combined-pass 候选。

### Full stored-vector 消融

| LUT segments | elements | different | strict abs failures | combined failures | max abs |
|---:|---:|---:|---:|---:|---:|
| 32 | 524,288 | 208,854 | 18 | 0 | 0.0001220703125 |
| 64 | 524,288 | 208,932 | 18 | 0 | 0.0001220703125 |

两个候选都通过 combined gate；软件模型当前选择最小的 32 段候选。其最坏
absolute-error 元素为 head=4、row=1、feature=84，actual=`0xBC8B`、
expected=`0xBC8A`、absolute error=`0.0001220703125`、ULP distance=1。
这是 stored project vector 软件结果，不是独立 hidden test 或硬件证据。

生成的临时报告 hash：

- Accuracy stress sweep: `901A5987CEFE0B7D0B21A2E83556E0CBD2C0CB9CBD0320A75A1357F15B2D3750`
- Accuracy full sweep: `5D88D1EB2761854A70B949E9EFC205915408E39931AAD7BD08B13CE9D3FD3102`

## Counter 与 II

Full 32/64 软件消融均闭合以下实际 counter：

| counter | issue | result | commit |
|---|---:|---:|---:|
| row | 4,096 | 4,096 | 4,096 |
| exp | 264,192 | 264,192 | 264,192 |
| valid weight | 264,192 | 264,192 | 264,192 |
| sum | 264,192 | 264,192 | 264,192 |
| reciprocal | 4,096 | 4,096 | 4,096 |

v3 公共 `weight_wr_accept` 目标为 524,288，因为每行还要把 masked 零写到
key=127；当前没有 wrapper/RTL 实测声称达到该数值。Compatibility 直接 RTL 的
定向无 stall burst 仍测得 exp issue II=1；Accuracy RTL II 未测量。

## 已执行测试

```powershell
python tests/check_cats_r4_lead_release.py
python tests/test_cats_r4_v3_capacity.py
python tests/test_cats_r4_b2_row_model.py
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\run_cats_r4_b2_softmax.ps1 -DiagnosticCases 256
python python/cats_r4_b2_row_model.py `
  --accuracy-stress-sweep --segments 16 32 64 128
python python/cats_r4_b2_row_model.py `
  --accuracy-full-sweep --segments 32 64
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\tests\run_v313_qk4_system_checks.ps1
```

结果：

- 恢复产物身份 / 8 个输入 hash：PASS；
- v3 capacity：4/4 PASS；
- B2 Python 直接单测：10 PASS；
- Compatibility RTL interleave/backpressure/numeric/reset：PASS；
- diagnostic seed `0xB200C0DE`：Compatibility combined failures=80/16,736；
  Accuracy 合法行 combined failures=0/16,731；两个非有限定向行被拒绝并计数；
- v3.1.4 system regression：PASS；full-GQA 4,096 rows / 524,288 elements /
  combined failures=0；
- Icarus `constant selects in always_*` 是模拟器能力提示，不是编译失败。

## B 源码 hash

| file | SHA-256 |
|---|---|
| `python/cats_r4_b2_row_model.py` | `114678E3CEB56CC4D46E591F37D73867404438163A6BE08A21973D598BDC49BC` |
| `tests/test_cats_r4_b2_row_model.py` | `DE4320A2A4B16ABF0EAACD2A55EE7269B5783C2FE663ECE2A600BC48D846EA0F` |
| `tests/run_cats_r4_b2_softmax.ps1` | `900FADCDF3BA12709C220E00FBB7E1D254E38D227C53C01F0CD826BE7B64D233` |
| `docs/CATS_R4_B2_NUMERIC_INTERFACE_CONTRACT.md` | `9F6573DE9E58492AD0267A195EF789B1CBC6F80E51F0C2D90CFFBBFAE6218C9D` |
| `docs/CATS_R4_B2_INTEGRATION_REQUEST.md` | `6C9F55F4408E8C5897DD42C70B82E8C2A78D2CABB836C153FC11EA8308ACCDC0` |
| `rtl/core/bc/softmax/cats_r4_row_softmax_compatibility.sv` | `568439A3363689654FFE27A06917DFC6B2A8FB831CFEB64DBB71594E10D4B200` |
| `tb/tb_cats_r4_row_softmax_compatibility.sv` | `2BB458D344F04F9E24C7D923DF37DE8B4CD55DA4A20E7D104791CBA9E0D7923B` |
| `tb/tb_cats_r4_row_softmax_compatibility_numeric.sv` | `71942F552F7ECE15AC6E1BA114BEE92144394AA51C7925D1DA72E61B8B4D8213` |
| `scripts/cats_r4_b2_softmax_ooc.tcl` | `668B22C0118B6A86B945FDC2EA9538298B28A0D708C29895DDF440FF6BC9FCAC` |

## 剩余阻塞与接口请求

1. `IR-B2-001` 仍 open：A/队长需冻结基于 v3 token 的 A→B row score/max
   精确握手。
2. 新增 `IR-B2-005`：v3 尚未定义 numeric/protocol error 后，B 如何撤销已部分
   写入的 weight slot；队长决定前，B 不自行增加公共 abort 端口。
3. Accuracy 范围缩减、插值、FP32 ordered sum 和 reciprocal 尚未实现为 RTL；
   真实 FP operator latency/rate/II 与综合属性未审计。
4. 本机仍未找到 Vivado/Vitis 2025.2；XSim、全新 root OOC synthesis、PPA、
   WNS、TNS 保持 `BLOCKED / NOT MEASURED`。
5. v3 wrapper 和 Accuracy RTL 缺失，因此尚无 524,288 weight writes、随机 v3
   backpressure/reset 或 full/stress Accuracy 硬件执行证明。

需要 A/C/队长：解决 `IR-B2-001` 与 `IR-B2-005`，随后提供或集中运行 Vivado
2025.2。B 继续停留在 B2；上述门禁及 Accuracy RTL 证据闭合前，不进入 B3，
不标 READY。
