# v2.3 冻结基线 SHA-256

- 冻结日期：2026-07-28
- 配置：8 Groups / 32Q / 8KV / S128 / D128 / BF16
- 板测：预热 1 次，正式 10 次，Combined failures = 0
- RTL 文件数：45
- RTL tree SHA-256：`86bf27e49e174a8d81dda83ff4cce0b481f0ad2a286a40256995c1cc12022f19`

| 产物 | 路径 | Bytes | SHA-256 |
|---|---|---:|---|
| bitstream | `vivado/fpt_attention_board_v2_8group/fpt_attention_board_v2_8group.runs/impl_1/attention_board_top.bit` | 28700869 | `85a531e7cca004c6e106ba5bc58c99eb7d58865d49d4134cc79a1e40102360cd` |
| xsa | `export/fpt_attention_board_v2_8group.xsa` | 2832525 | `9c420257f3853bf2878a2fe5190e42173bca7bc3fb8d1eb05985f74e1e5da73c` |
| elf | `vitis/workspace/fpt_attention_test/Debug/fpt_attention_test.elf` | 2936792 | `3b227851a12200d9115a634c87b70a6ecb06ded46ba55adcdc3838efcf3d9924` |
| board_log | `logs/v2.3_hardware_profile_10run.txt` | 9147 | `e9ce1c93a8854748280a7625bec143e5cb264ebbb51159daabc19e6e1adfaefe` |
| timing_report | `reports/timing_summary_impl.rpt` | 835705 | `ec469701276db34eac0d8ca24449e33706e1f1ebadb5fdbb4e7c30aec3bbf6de` |
| utilization_report | `reports/utilization_impl.rpt` | 1739515 | `f4681202d14600aa1743bd568c09bedb75329e5f4f5e6463f7224b8921569483` |
| power_report | `reports/power_impl.rpt` | 12295 | `2f7af52cadcc78f3c756ed7647ab00c31e4ea5c25aa18d1273c57347b17bfc6f` |
| original_workspace_zip | `../FPT_XCZU15EG_Attention_Board_v2.0.zip` | 369075566 | `42ec9e2065d5a4b876139d84f71997837deeac0eb5845cadb34cec402e7f9d72` |

RTL tree hash 的输入为按相对路径排序的每个 `.v`/`.sv` 文件路径与其 SHA-256。
该文档标识冻结时的 v2.3；后续工作区 RTL 变化不会改变已生成的基线压缩包。
