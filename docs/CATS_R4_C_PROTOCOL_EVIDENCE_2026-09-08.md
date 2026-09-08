# C bridge protocol-only evidence

运行日期：2026-09-08。源分支：`codex/cats-r4-local-integration`。

命令：

```powershell
iverilog -g2012 -DCATS_R4_PROTOCOL_ONLY -s tb_cats_r4_qkv_axi_bank_bridge `
  -o artifacts/raw_logs/bridge_protocol_vvp/bridge.vvp `
  rtl/core/cluster/cats_r4_qkv_axi_bank_bridge.sv `
  tb/tb_cats_r4_qkv_axi_bank_bridge.sv
vvp artifacts/raw_logs/bridge_protocol_vvp/bridge.vvp
```

结果：`PASS: CATS-R4 AXI/core bank bridge descriptors and counters`。

已实际覆盖：Q 512 beats、K 4096 beats、V 4096 beats、descriptor completion、
premature `wr_last` sticky error、reset reopen、token mismatch rejection。
原始运行输出位于 `artifacts/raw_logs/bridge_protocol_vvp/`，该目录属于本地原始证据，
没有把生成的 vvp 临时文件加入源代码提交。

## 证据边界

这是 protocol-only 仿真，`CATS_R4_PROTOCOL_ONLY` 排除了 XPM RAM 和 core readback。
它不证明 bank readback、真实 XPM N+2、CDC、4 KiB burst split、短尾 AXI、v3 weight slab
或 C2 counter closure。对应门禁仍保持 `NOT_READY`。真实 Vivado 可用后，必须另跑脚本的
protocol runtime、default-XPM static elaboration，并补真实 XPM 连续读证据。
