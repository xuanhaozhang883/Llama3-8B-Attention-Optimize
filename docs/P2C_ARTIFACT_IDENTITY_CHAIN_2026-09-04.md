# P2C v3.1.4 产物身份链

## 结论

P2C 通过。Vitis 2025.2 在此前不存在的短 ASCII 工作区 `D:/Vitis/FPT/tmp/p2c_vitis_84a69f7_01` 中，从 P2B 本次导出的 v3.1.4 含 bit XSA 全新生成 platform、standalone BSP、A53 应用和 ELF。没有使用恢复阶段借用的 v3.1.3 XSA，也没有复用旧 BSP。

本结论只证明硬件与软件产物匹配且 ELF 可编译；本阶段没有连接、复位或编程板卡，不证明板上正确性或性能提升。

## 构建输入与工具

- 源码提交：`84a69f707070cb2f3c583642d4cf470552e174da`（`codex/v314-causal-bypass`）。
- Vivado：2025.2 Build 6299465。
- Vitis/XSCT：2025.2.0 SW Build 6298600。
- `FPT_XSA_OVERRIDE`：`D:/Vitis/FPT/FPT_WORKSPACE/03_work_v314_causal_bypass/export/fpt_attention_board_v314_qk4_causal_bypass.xsa`。
- `FPT_VITIS_WORKSPACE`：`D:/Vitis/FPT/tmp/p2c_vitis_84a69f7_01`；运行前不存在。
- 构建脚本：`scripts/create_vitis_app_xsct.tcl`；目标为 `psu_cortexa53_0`、standalone，执行 `platform create/generate`、`app create`、源码导入和应用构建。
- ELF 完成时间：2026-09-04 16:53:45 +08:00。

## 接口审计

新 BSP 的 `xparameters.h` 和实际预处理结果确认：

- CPU 为 Cortex-A53：`XPAR_PSU_CORTEXA53_0_*`，应用目标为 `psu_cortexa53_0`。
- A53 连接到 `axi_gpio_ctrl`；驱动为 AXI GPIO。
- GPIO 范围为 `0x80000000-0x8000FFFF`，双通道、无中断。通道 1 写控制字，通道 2 读状态/性能页，与软件寄存器访问一致。
- PS DDR0 范围为 `0x00000000-0x7FEFFFFF`；Q/K/V/Context 的 `0x10000000/0x10100000/0x10140000/0x10180000` 均在该范围内。
- 编译命令未从外部传入覆盖宏；对同一源码和本次 BSP 执行预处理后得到 `#define FPT_V314_CAUSAL_BYPASS 1`，所以该 ELF 使用 v3.1.4 causal consumer bypass 计数契约。
- ELF 头为 ELF64、little-endian、AArch64、EXEC。

## 哈希身份链

| 产物 | SHA-256 | 绝对路径 |
|---|---|---|
| P2B BIT | `1C2B74DD7E2FA31C0EBE4AA991BC3B278A837525987A3BA975ACAD601B0A83D5` | `D:/Vitis/FPT/tmp/p2b_board_c1f41fe_01/fpt_attention_board_v314_qk4_causal_bypass/fpt_attention_board_v314_qk4_causal_bypass.runs/impl_1/attention_board_top.bit` |
| P2B 含 bit XSA | `DD878BF6AC48D33F61BD7E504B550B29B869476253AD7DB6325F793A8E86A2EB` | `D:/Vitis/FPT/FPT_WORKSPACE/03_work_v314_causal_bypass/export/fpt_attention_board_v314_qk4_causal_bypass.xsa` |
| P2C A53 ELF | `95B477F5FC7D3B1032FC34F4833EC0D0090DCECD3C3FF17109F23F8C38A87C94` | `D:/Vitis/FPT/tmp/p2c_vitis_84a69f7_01/fpt_attention_test/Debug/fpt_attention_test.elf` |

XSA 内部 `FULL_BIT` 条目的 SHA-256 也是 `1C2B74...A83D5`，与独立 BIT 完全一致。新 ELF 的 SHA-256 不等于禁止使用的恢复阶段临时 ELF 哈希 `BAD016...4E`。

机器可读记录见 `artifacts/P2C_ARTIFACT_MANIFEST_2026-09-04.json`。BIT、XSA、ELF 二进制不纳入 Git；manifest 记录其绝对路径、大小和哈希。

## 后续边界

下一步只能按 `docs/BOARD_BRINGUP_TUTORIAL_V314.md` 进行板级 Gate。必须保存原始 UART 日志并核对 1 次 warm-up、10 次正式运行、`combined_failures=0`、v3.1.4 完整计数和错误标志。未得到这些证据前，不得写“上板通过”或把预测的 240～280 ms 当作实测。
