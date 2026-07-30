# FPT XCZU15EG Attention v2.4 — 细粒度性能计数器实体板通过版

> 当前状态：Vivado/Vitis 2024.2 构建、XCZU15EG 实体板预热 1 次和
> 正式 10 次测量均已完成。v2.4 正确运行 10/10、确定性运行 10/10、
> Combined failures=0；v2.3 继续保留为不可破坏的回退基线。

本目录以已冻结的 v2.3 干净基线为起点，只增加性能观察路径、GPIO
profiling page、A53日志和Python分析，不改变 Attention 数值数据通路。

先阅读：

- `doc/STAGE0_ARCHIVE_AUDIT.md`
- `doc/STAGE1_PROFILE_COUNTER_DESIGN.md`
- `doc/V2_4_BOARD_PASS_RECORD.md`
- `STATUS.md`

## v2.4 验证摘要

| 指标 | 结果 |
|---|---:|
| 正确运行 / 确定性运行 | 10/10 / 10/10 |
| 平均延迟 | 1843.689 ms |
| 平均 PL 周期 | 276,550,484 |
| 实测 PL 时钟 | 149.998 MHz |
| WNS / TNS | +1.146 ns / 0 |
| LUT / FF / BRAM Tile / DSP | 51,679 / 36,888 / 99.5 / 136 |
| B+C / real-PV overlap | 0 cycles |
| Real-PV feed stall | 115,605,520 cycles（41.802%） |

完整证据见 `logs/v2.4_hardware_profile_10run.txt`、
`reports/profile_v2.4/` 和 `doc/V2_4_BOARD_PASS_RECORD.md`。

快速静态检查：

```bash
python python/audit_package.py
python python/validate_profile_contract.py
```

Vivado 2024.2 Tcl Console：

```tcl
cd C:/lhm/2_Work/4_FPT/FPT_XCZU15EG_Attention_v2.4_profile_source
source scripts/check_rtl_elaboration.tcl
```

必须使用 `/`，不要在 Tcl 的 `cd` 路径中直接写 Windows 反斜杠。
脚本会把 Vivado 生成文件放到相邻的短路径：

```text
C:/lhm/2_Work/4_FPT/_fpt_v24_build/
```

因此无需再次移动源码目录，也不会引用
`C:/lhm/2_Work/pl_read_write_ps_ddr.gen/` 中的旧工程文件。

上述命令用于干净环境复现。当前归档版本已经重新生成 bit/XSA/ELF 并完成
10 次正确性测试；复现时仍应以相同验收条件重新检查，不能仅凭静态检查或
bitstream 存在就宣称板级通过。

---

# v2.3 基线说明 — 完整 8 GQA Group

## 1. 目标

本目录名称沿用 v2.0，但当前已经实体板验证的实际基线为 **v2.3-board-profile**。本版在已上板 PASS 的 v1.7/v1.8 单 Group 基线上，将硬件运行范围扩展到 Llama-3.1-8B Attention 的完整 Head 配置：

```text
RUN_GROUPS = 8
Query Heads = 32
KV Heads = 8
GQA ratio = 4Q : 1KV
SEQ_LEN = 128
HEAD_DIM = 128
Datatype = BF16
```

注意：这里完成的是完整 32Q/8KV Head；序列长度仍为竞赛当前硬件切片的 128，不是模型标称的 128K 上下文。

## 2. Golden 数据来源

本包的数据由 `golden_model_outputs/full` 生成：

```text
Q       full/q_before_rope.npy[:32, :128, :] → [32,128,128]
K       full/k_before_rope.npy[:8, :128, :]  → [8,128,128]
V       full/v.npy[:8, :128, :]              → [8,128,128]
Context full/attn_out_per_head.npy[:32,:128,:] → [32,128,128]
```

原始 full 数据的 sequence 为 256。本版只取前 128 个 token。由于开启 causal mask，前 128 行不会依赖后 128 个 token。生成脚本同时确认 Group 0 与已上板 PASS 的 v1.7 数据逐字一致。

## 3. DDR 地址与容量

| 区域 | 基地址 | 大小 | 布局 |
|---|---:|---:|---|
| Q | `0x10000000` | 1,048,576 B | `[32][128][128]` BF16 |
| K | `0x10100000` | 262,144 B | `[8][128][128]` BF16 |
| V | `0x10140000` | 262,144 B | `[8][128][128]` BF16 |
| Context | `0x10180000` | 1,048,576 B | `[32][128][128]` BF16 |
| AXI GPIO | `0x80000000` | 64 KiB aperture | PS 控制/状态 |

四个数据区域首尾相接且不重叠。

## 4. 本版修改

- `attention_board_top.RUN_GROUPS` 默认值改为 8；
- V Loader 装载 8 个 KV Head；
- Attention Controller 依次运行 Group 0～7；
- Q/K Reader 使用 global Q head 0～31、global K head 0～7；
- Context Writer 写回全部 32 个 Q Head；
- A53 装载完整 Q/K/V，并比较 `524288` 个 Context BF16；
- 串口在 active group 变化时打印进度；
- Python 脚本支持从上传的 full Golden NPY/ZIP 重新生成数据；
- Tcl 使用集中配置，工程名为 `fpt_attention_board_v2_8group`。

核心 QK/Softmax/PV 计算结构没有复制 8 份，而是按 Group 顺序复用同一套计算资源，因此预计资源量接近单 Group，运行时间约按 Group 数增长。

## 5. 离线检查结果

本包生成时已通过：

```text
完整数据形状和 BF16 字数检查
Group 0 与 v1.7 数据回归一致
Raw Q/K split-half DDR 布局
V 64-bit beat 拆分
PV TILE4 → Context 行主序重排模型
四段 DDR 地址无重叠
39 个核心 HDL + 6 个板级 HDL
模块重名与必需模块检查
生成目录清理检查
```

## 6. v2.3 实体板基线

v2.3 已在 XCZU15EG 上完成预热 1 次、正式测量 10 次：

| 指标 | 结果 |
|---|---:|
| 正确运行 | 10 / 10 |
| Combined failures | 0 |
| 平均延迟 | 1843.689 ms |
| PL 总周期 | 276,550,520 |
| 实测 PL 时钟 | 149.998 MHz |
| Effective QK+PV | 0.1456 GFLOP/s |
| B+C busy | 156,648,602 cycles |
| Real PV busy | 119,799,808 cycles |

正确性使用 `abs_error <= 1e-4 OR BF16_distance <= 1 ULP`。结果不是 bit-exact。原始日志见 `logs/v2.3_hardware_profile_10run.txt`。

## 7. Vivado 构建

当前可直接使用你现有的源码路径：

```text
C:/lhm/2_Work/4_FPT/FPT_XCZU15EG_Attention_v2.4_profile_source/
```

Vivado 2024.2 Tcl Console：

```tcl
cd C:/lhm/2_Work/4_FPT/FPT_XCZU15EG_Attention_v2.4_profile_source
source scripts/check_rtl_elaboration.tcl
```

输出：

```text
C:/lhm/2_Work/4_FPT/_fpt_v24_build/fpt_attention_board_v2_8group/
export/fpt_attention_board_v2_8group.xsa
reports/profile_v2.4/*.rpt
```

RTL展开通过后，再运行完整前台构建：

```tcl
source scripts/build_profile_foreground.tcl
```

如需把生成目录放到更短的位置，可在运行脚本前设置：

```tcl
set ::env(FPT_VIVADO_BUILD_ROOT) C:/fpt_build/v24
```

## 8. Vitis 构建

在 XSCT：

```tcl
cd C:/lhm/2_Work/4_FPT/FPT_XCZU15EG_Attention_v2.4_profile_source
source scripts/create_vitis_app_xsct.tcl
```

完整 Golden Header 的 C 源码较大，首次编译会比单 Group 慢；生成 ELF 中的二进制数据约 2.5 MiB，PS DDR 容量足够。

## 9. 板上下载

继续使用已验证的无 GTR 初始化流程：

```tcl
set root C:/lhm/2_Work/4_FPT/FPT_XCZU15EG_Attention_v2.4_profile_source
set psu_init <当前工程生成的psu_init.tcl完整路径>
set app_elf [file join $root vitis workspace fpt_attention_test Debug fpt_attention_test.elf]
set argv [list $psu_init $app_elf]
source [file join $root scripts run_on_board_no_gtr_xsct.tcl]
```

预期结果：

```text
Progress: active group 1 / 8
...
Progress: active group 8 / 8
busy=0 done=1 error=0 v=1 core=1 ctx=1
Context tolerance failures : 0 (tol=1e-4)
[PASS] v2.3 hardware profiling and ten-run benchmark passed
```

## 10. 重新生成 Golden 数据

```bash
python python/prepare_golden_vectors.py --source C:/path/golden_model_outputs.zip
python python/verify_data_layout.py
python python/audit_package.py
```

当前实现与实体板验证结果见 `reports/`、`doc/BOARD_PASS_RECORD.md` 和 `logs/v2.3_hardware_profile_10run.txt`。`audit_package.py` 用于检查解压后的干净发布包，不能直接对包含 `vivado/`、`.Xil/` 和 `vitis/workspace/` 的开发目录运行。
