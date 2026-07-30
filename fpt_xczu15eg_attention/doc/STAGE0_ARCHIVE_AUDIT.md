# 阶段0：v2.3 归档检查

检查日期：2026-07-29  
检查对象：上传工作区中的
`releases/FPT_XCZU15EG_Attention_v2.3_baseline_clean.zip`

## 结论

该文件可以作为当前唯一权威的 v2.3 回退基线。它通过了 ZIP 完整性、
源码结构、Golden 数据、关键产物哈希和板级证据检查。

外层 `FPT_XCZU15EG_Attention_Board_v2.0 - 副本` 在本次阶段0审计时是
开发工作区快照，包含 Vivado/Vitis 生成目录和当时尚未完成板测的 v2.4
计数器修改，因此不能替代干净 v2.3 冻结包。此后 v2.4 已于
2026-07-29 完成实体板 10-run 验证；其通过证据独立记录在
`V2_4_BOARD_PASS_RECORD.md`，不改变本文件对 v2.3 冻结包的审计结论。

## 已通过项目

| 检查项 | 结果 |
|---|---|
| ZIP CRC | PASS |
| 干净包静态审计 | PASS |
| 核心/板级 HDL | 39 / 6，共45个文件 |
| 唯一 module | 46 |
| Golden Q/K/V/Context | 完整，字数与32Q/8KV/S128/D128一致 |
| ROM/LUT | sin、cos、exp LUT字数正确 |
| Block Design | `bd_base/design_1/design_1.bd`存在 |
| bitstream | 28,700,869 B，SHA-256匹配 |
| XSA | 2,832,525 B，SHA-256匹配 |
| ELF | 2,936,792 B，SHA-256匹配 |
| RTL tree SHA-256 | `86bf27e49e174a8d81dda83ff4cce0b481f0ad2a286a40256995c1cc12022f19` |
| 10-run日志 | 10/10正确，Combined failures=0 |
| Timing | 150.015 MHz，WNS=+1.023 ns，TNS=0 |
| PPA报告 | utilization、timing、DRC、power齐全 |
| 生成垃圾 | `.Xil`、Vivado runs、Vitis workspace均未进入干净包 |
| 发布包SHA-256 | `bf0cc2b315f7a67a8cb6af7c04d746f5a16b2e68ef43e1ad17c08c817a26964d` |

## 正确性口径

冻结基线满足：

```text
abs_error <= 1e-4 OR BF16_distance <= 1 ULP
```

Exact mismatches 为 225,853 / 524,288，因此只能表述为“通过混合误差
判据”，不能表述为 bit-exact。

## 非阻塞问题

1. `PACKAGE_MANIFEST.json`覆盖98个源码/数据/报告文件，三个二进制产物
   未列入该JSON，但它们已由`doc/V2_3_BASELINE_SHA256.md`单独记录并核验。
2. 外层开发工作区缺少原始 Vivado `impl_1` 路径下的 `.bit`，但干净
   冻结包中的`artifacts/attention_board_top.bit`完整且哈希正确。
3. 冻结文档中的`original_workspace_zip`是来源追溯记录，不是干净包
   内部依赖。

以上三项不影响 v2.3 作为回退/提交基线，但后续所有实验版本必须使用
新的版本名，禁止覆盖该ZIP。
