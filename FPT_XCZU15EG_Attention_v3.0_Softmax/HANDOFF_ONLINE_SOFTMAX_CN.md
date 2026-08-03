# FPT v3.0 Online Softmax 使用与交接说明

## 1. 交付结论

对外交付名称为 `FPT_XCZU15EG_Attention_v3.0_Softmax`。该版本基于 v2.6 Causal Dual-Tile，使用 Online 输入/输出流水和精确分母校正，已经完成 Vivado/Vitis 2024.2 构建、XCZU15EG 实体板 warm-up 以及 10 次正式回归。

最终结论：10/10 正确、10/10 确定、Combined failures=0，可以作为正式上传版本。

## 2. 已关闭问题

### 2.1 跨行输入丢拍

原 Online Softmax 在上一行最后一个输出握手时清除了 `raw_stage_valid/load_stage_valid`，丢弃已经握手的下一行前两个元素。板级表现为 Context 全零、PV/DDR 写入不启动、error bitmap `0x000004C0`。

修复后，正常行结束保留已接收流水拍；复位和异常恢复仍可清空。

### 2.2 四路分母归约数值偏移

四路 Online `(m,l)` 归约改变了定点舍入顺序，第一次结构修复后的板测仍有 2 个输出达到 2/4 ULP。

最终实现使用流水化精确分母扫描：按最终全局最大值逐列计算 EXP LUT 并以旧版顺序累加 Q1.15 值。与归档旧 Softmax 的 1024 个完整行概率逐比特一致，板级恢复为最大 1 ULP、Combined failures=0。

判据从未放宽，黄金数据未修改。

## 3. 最终硬件产物

| 产物 | Bytes | SHA-256 |
|---|---:|---|
| `export/fpt_attention_board_v30_causal_dualtile.bit` | 28,700,869 | `a770ccb457e30b32bcb7aa4270f2bca4a8c784369b752370b0631841628db31f` |
| `export/fpt_attention_board_v30_causal_dualtile.xsa` | 772,801 | `a1956de4a740be0b06c2824cc74e6eb03dce904775ca07daaf60caef713ec8f1` |
| `rtl/core/bc/softmax/softmax_bf16.sv` | — | `a75940db10016ed5e330f7e35ed3fa690f4eea47a7a643185440a790c4571249` |

v30 是对外文件名；`fpt_attention_board_v26_causal_dualtile.*` 是内容相同的内部脚本兼容文件。BIT 与 XSA 必须配套使用。

## 4. 签核结果

工具与器件：Vivado/Vitis 2024.2，`xczu15eg-ffvb1156-2-i`，150 MHz。

| 指标 | 结果 |
|---|---:|
| WNS / TNS | +1.327 ns / 0 ns |
| WHS / THS | +0.010 ns / 0 ns |
| DRC Error / Critical Warning | 0 / 0 |
| Total LUT / FF | 32,797 / 66,443 |
| RAMB36 / RAMB18 | 173 / 5 |
| DSP | 267 |
| Power（vectorless） | 4.490 W |

## 5. 仿真回归

```text
SOFTMAX_ONLINE_TEST: PASS
ONLINE_SOFTMAX_REGRESSION: PASS
EQ_VECTOR_TEST: PASS
CONTINUOUS_ROWS_TEST: PASS input=512 output=512
FULL_BACKEND_TEST: PASS input=65536 prob=65536 vec=524288
1024/1024 full-row bit-exact: PASS
V26_ARCHITECTURE_CHECK: PASS
```

单行 Softmax 为 443 cycles，归档旧版约 1202 cycles。

## 6. 实体板结果

```text
Correct runs              : 10 / 10
Deterministic result runs : 10 / 10
Combined failures         : 0
Maximum BF16 distance     : 1 ULP
Average latency           : 429.393630 ms
Total PL cycles           : 64408268
Error detail bitmap       : 0x00000000
Causal error flags        : 0x00000000
```

固定计数：QK `2112/1984`、PV `4227072/4161536`、Native TILE4 `4194304`、Context `524288`。

原始证据位于 `logs/v3.0_online_softmax_exact_denom_10run_pass.txt`。

## 7. 重新生成 BIT/XSA

内部构建脚本仍使用 v26 工程名。Windows 必须使用物理短路径，不要使用 junction：

```powershell
$env:FPT_VIVADO_BUILD_ROOT = "C:/b26exact"
$env:XILINX_LOCAL_USER_DATA = "no"
Set-Location C:/w26fix
& C:/Software/AMD/vivado24.2/Vivado/2024.2/bin/vivado.bat \
  -mode batch \
  -source scripts/build_profile_foreground_ipfix.tcl
```

构建生成内部 v26 文件；发布时复制为 v30 文件名并重新核对 SHA-256。不要仅重命名不明来源的旧产物。

## 8. 重建 Vitis

每次 XSA 变化后运行：

```powershell
& C:/Software/AMD/vivado24.2/Vitis/2024.2/bin/xsct.bat \
  scripts/create_vitis_app_xsct.tcl
```

预期 ELF：FSBL、PMUFW 和 `vitis/workspace/fpt_attention_test/Debug/fpt_attention_test.elf`。

## 9. 上板下载

串口设置为 115200、8N1、无流控。关闭占用 JTAG 的其他进程并重新上电：

```powershell
& $Xsct scripts/run_on_board_no_gtr_xsct.tcl $PsuInit $Elf
```

测试程序末尾的 `[PASS] v2.4 fine-grained profiling...` 是遗留字符串，不代表实际硬件版本。应以 v3.0 产物哈希及本交接记录判断。

## 10. 上传前检查

1. 校验 v30 BIT/XSA 哈希；
2. 确认 `PACKAGE_MANIFEST.json` 为 v3.0 且 `board_verified=true`；
3. 确认包含最终串口日志和 Vivado 2024.2 报告；
4. 不上传 `.Xil/`、Vitis workspace、短路径构建目录、许可证或备份目录；
5. 不以中间失败日志替代最终 PASS 日志。

