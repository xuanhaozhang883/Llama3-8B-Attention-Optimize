# FPT XCZU15EG Attention v3.0 — Online Softmax 精确分母版

> 对外交付名称：`FPT_XCZU15EG_Attention_v3.0_Softmax`
>
> 最终状态：Vivado/Vitis 2024.2 构建签核通过，XCZU15EG 实体板 warm-up + 10-run 全部通过。

## 1. v3.0 内容

v3.0 基于已验证的 v2.6 Causal Dual-Tile 架构，保留：

- 8 GQA groups，32Q/8KV，S=128，D=128，BF16；
- 跨 Group Ping-Pong；
- Causal QK whole-tile skip；
- 双 4×4 QK、原生 TILE4 capture；
- Causal PV row-effective reduction、双 4×4 PV。

Softmax 路径新增两项正式修复：

1. 保留在上一行结束前已经完成 ready/valid 握手的下一行输入拍，消除跨行丢拍、`0x4C0` 错误位图和 Context 不写回；
2. 使用流水化精确分母扫描，按最终全局最大值逐列累加 Q1.15 EXP LUT 值，恢复与归档旧 Softmax 逐比特一致的概率，同时保持每周期一个概率输出。

不修改黄金向量，也不放宽 `abs<=1e-4 OR BF16 distance<=1 ULP` 判据。

## 2. 最终验证摘要

| 项目 | 结果 |
|---|---:|
| Softmax 单行仿真延迟 | 443 cycles（归档旧版约 1202） |
| 归档旧版逐比特等价 | 1024 / 1024 PASS |
| 完整 Softmax→PV 回归 | 65536 概率、524288 Context PASS |
| Vivado 版本 | 2024.2 |
| WNS / WHS | +1.327 ns / +0.010 ns |
| TNS / THS | 0 / 0 |
| DRC Error / Critical Warning | 0 / 0 |
| Warm-up | PASS |
| 正确运行 | 10 / 10 |
| 确定性运行 | 10 / 10 |
| Combined failures | 0 |
| 平均延迟 | 429.393630 ms |
| Total PL cycles | 64,408,268 |
| Effective QK+PV | 0.625 GFLOP/s |

固定计数：QK `2112/1984`、PV `4227072/4161536`、Native TILE4 `4194304`、Context `524288`，error bitmap 和 causal flags 均为 0。

## 3. 最终产物

| 产物 | Bytes | SHA-256 |
|---|---:|---|
| `export/fpt_attention_board_v30_causal_dualtile.bit` | 28,700,869 | `a770ccb457e30b32bcb7aa4270f2bca4a8c784369b752370b0631841628db31f` |
| `export/fpt_attention_board_v30_causal_dualtile.xsa` | 772,801 | `a1956de4a740be0b06c2824cc74e6eb03dce904775ca07daaf60caef713ec8f1` |
| `rtl/core/bc/softmax/softmax_bf16.sv` | — | `a75940db10016ed5e330f7e35ed3fa690f4eea47a7a643185440a790c4571249` |

`v30` 文件是对外交付入口。内部 `v26` BIT/XSA 文件与其逐比特相同，为现有 Tcl/XSCT 构建脚本保留。

## 4. 快速验证

Vivado XSIM 回归：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\run_online_softmax_vivado.ps1 \
  -VivadoRoot C:\Software\AMD\vivado24.2\Vivado\2024.2
```

与归档旧 Softmax 完整行逐比特比较：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\compare_online_softmax_to_archive.ps1 \
  -VivadoRoot C:\Software\AMD\vivado24.2\Vivado\2024.2
```

架构静态检查：

```powershell
python .\python\validate_v26_architecture.py
```

## 5. 重新构建

内部构建入口保持兼容：

```cmd
02_build_v26_bitstream.bat
03_build_vitis_v26.bat
```

Windows 下应使用物理短路径作为源码和构建目录。经过验证的前台入口为：

```powershell
$env:FPT_VIVADO_BUILD_ROOT = "C:/b26exact"
& C:\Software\AMD\vivado24.2\Vivado\2024.2\bin\vivado.bat \
  -mode batch \
  -source scripts/build_profile_foreground_ipfix.tcl
```

新 XSA 生成后必须重新创建 Vitis platform 和 ELF，不得把新 BIT 与旧 platform/ELF 混用。

## 6. 上板入口

串口：115200、8N1、无流控。下载入口：

```powershell
& $Xsct scripts\run_on_board_no_gtr_xsct.tcl $PsuInit $Elf
```

测试程序末尾的 `[PASS] v2.4 fine-grained profiling...` 是遗留显示标签；版本判断以本文件、产物哈希和 v3.0 板测记录为准。

## 7. 权威记录

- 交接说明：`HANDOFF_ONLINE_SOFTMAX_CN.md`
- 板测记录：`doc/BOARD_PASS_RECORD.md`
- Softmax 修复与验证：`doc/ONLINE_SOFTMAX_OPTIMIZATION.md`
- 最终 SHA-256：`doc/V3_0_RELEASE_SHA256.md`
- 原始串口日志：`logs/v3.0_online_softmax_exact_denom_10run_pass.txt`
- Vivado 报告：`reports/v2.6_causal_dualtile/`（内部兼容目录名）
- 当前状态：`STATUS.md`

