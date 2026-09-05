# v3.1.4 上板教程（P2C 后续步骤）

这份教程用于下一阶段板级 Gate。本轮 P2C 没有执行以下板卡命令。目标不是“能打印串口就算成功”，而是确保使用同一身份链的 BIT/XSA/ELF，保存完整原始日志，再由脚本签核正确性和计数。

## 1. 准备硬件与软件

需要：XCZU15EG `xczu15eg-ffvb1156-2-i` 板卡、匹配电源、JTAG、UART、稳定散热，以及安装了 Vivado/Vitis 2025.2 和驱动的 Windows 主机。

1. 板卡断电。
2. 按板卡手册把启动模式设为 JTAG。不要凭相似板卡的拨码图猜测；先拍照记录当前拨码。
3. 接好 JTAG 和 UART，再接电源。UART 参数设为 115200、8 data bits、no parity、1 stop bit、no flow control。
4. 串口工具开启“保存原始文本到文件”，建议文件名 `logs/v314_board_YYYYMMDD_HHMMSS.log`。不要只截图。
5. 确认没有另一个 Vivado/Vitis/hw_server 会话占用同一 JTAG。

### RK-XCZU15EG_F V1.0 串口选择

该底板有两个外观相同的 USB-C/CH340K 串口，不能只凭 Windows 中的 `CH340` 设备名选择：

- `USB3`（板上丝印 `PS UART`）：经 U16 CH340K 和 U15 电平转换器连接到 PS UART0，`MIO42=RX`、`MIO43=TX`。本工程必须使用此口。
- `USB4`（板上丝印 `PL UART`）：经 U17 CH340K 连接到 PL UART 网络；本工程未用该网络输出 `xil_printf`，连接此口会出现 COM 口可打开但没有 benchmark 日志。

按底板正面位号图方向，`PS UART` 位于上边缘、靠近 CAN 接口和 J22；`PL UART` 位于下边缘、靠近 RS485 接口和按键。若只连接其中一个串口，拔插对比设备管理器中的 COM 号，并确认 USB 线实际插在 `PS UART` 后再运行 ELF。

## 2. 上电前核对三件套

在 PowerShell 中执行以下只读命令：

```powershell
$bit = 'D:\Vitis\FPT\tmp\p2b_board_c1f41fe_01\fpt_attention_board_v314_qk4_causal_bypass\fpt_attention_board_v314_qk4_causal_bypass.runs\impl_1\attention_board_top.bit'
$xsa = 'D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass\export\fpt_attention_board_v314_qk4_causal_bypass.xsa'
$elf = 'D:\Vitis\FPT\tmp\p2c_vitis_84a69f7_01\fpt_attention_test\Debug\fpt_attention_test.elf'
Get-FileHash -Algorithm SHA256 -LiteralPath $bit,$xsa,$elf
```

只有结果逐字等于以下值才继续：

- BIT：`1C2B74DD7E2FA31C0EBE4AA991BC3B278A837525987A3BA975ACAD601B0A83D5`
- XSA：`DD878BF6AC48D33F61BD7E504B550B29B869476253AD7DB6325F793A8E86A2EB`
- ELF：`95B477F5FC7D3B1032FC34F4833EC0D0090DCECD3C3FF17109F23F8C38A87C94`

任一文件缺失或哈希不同，立即停止，不要用“名字相同”的旧文件替代。

## 3. 只探测 JTAG

打开 PowerShell，进入活动工程：

```powershell
Set-Location 'D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass'
& 'D:\Vitis\2025.2\Vitis\bin\xsct.bat' 'scripts\probe_board_xsct.tcl'
```

此脚本只连接并列出目标，不复位、不烧写。确认列表中是预期的 Zynq UltraScale+ MPSoC/PSU；若没有目标，按“电源→JTAG 线→驱动→启动拨码→hw_server 占用”的顺序排查。不要在目标身份不明确时继续。

## 4. 确认本次 PS 初始化文件

使用由 P2C 同一 XSA 生成的文件：

```text
D:\Vitis\FPT\tmp\p2c_vitis_84a69f7_01\fpt_attention_platform\hw\psu_init.tcl
```

不要使用 v3.1.3 workspace 中的 `psu_init.tcl`。本工程只使用 PS DDR、UART 和 PS-PL AXI；仓库中的下载脚本采用 no-GTR 初始化，避免未使用的 USB/PCIe/DP/SATA GTR 锁定轮询阻塞。

## 5. 一次性下载并启动

确认串口已经开始记录，然后在 PowerShell 执行：

```powershell
$env:FPT_VIVADO_BUILD_ROOT = 'D:\Vitis\FPT\tmp\p2b_board_c1f41fe_01'
$psuInit = 'D:\Vitis\FPT\tmp\p2c_vitis_84a69f7_01\fpt_attention_platform\hw\psu_init.tcl'
$elf = 'D:\Vitis\FPT\tmp\p2c_vitis_84a69f7_01\fpt_attention_test\Debug\fpt_attention_test.elf'
& 'D:\Vitis\2025.2\Vitis\bin\xsct.bat' 'scripts\run_on_board_no_gtr_xsct.tcl' $psuInit $elf
```

脚本按顺序执行：连接 PSU、系统复位、初始化 MIO/时钟/DDR/UART/AXI、下载 P2B BIT、解除 PS-PL 隔离和复位、选择 Cortex-A53 #0、下载 P2C ELF、继续运行。不要在脚本执行中途断电或拔 JTAG。

## 6. 观察完整运行

程序会自动执行：加载完整 Q/K/V 到 DDR、1 次 warm-up 正确性门禁、10 次正式运行和汇总。无需在串口输入命令。

必须看到：

- banner 为 `FPT XCZU15EG FlashAttention v3.1.4 QK4/V8 causal-bypass benchmark`；
- GPIO base 为 `0x80000000`；
- `[PASS] Warm-up correctness gate passed`；
- 10 条 `PERF_CSV`、10 条 `HWPROF_CSV`、10 条 `V26_CAUSAL_CSV`、10 条 `V31_FLASH_CSV`；
- `[PASS] v3.1 FlashAttention ten-run correctness and profiling passed`；
- 每次 `combined_failures=0`，错误位图和 causal error flags 均为 0；
- 每次 QK computed/skipped 为 `16896/15872`，masked emitted 为 `15872`；
- 每次 Context processed/bypassed 为 `16896/15872`；两者之和为 32,768 个 FIFO tile；
- 每次 V vectors 为 `1081344`，Context words 为 `524288`。

当前 GPIO profile 没有独立导出 FIFO enqueue/dequeue 两个计数器；板级日志以 QK 总 tile `16896+15872=32768`、consumer processed+bypassed `16896+15872=32768` 和错误标志共同验证生产/消费总量。不要把这个推导写成“独立 FIFO 计数器实测”。

## 7. 保存并机器签核日志

程序输出完成后先保存并复制一份只读原始 UART 日志，再执行正确性签核：

```powershell
$repo = 'D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass'
$log = y'm'D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass\logs\v314_board_YYYYMMDD_HHMMSS.log'
python "$repo\python\signoff_v31_board_log.py" $log --profile v314-causal-bypass --correctness-only --json "$repo\logs\v314_board_signoff.json" --markdown "$repo\logs\v314_board_signoff.md"
Get-FileHash -Algorithm SHA256 -LiteralPath $log
```

`--correctness-only` 仍强制检查 10 次运行、数值、完整硬件计数和错误标志，只是不把旧 v3.0 的 10% 性能阈值作为本次首次上板的通过条件。需要正式性能签核时，保留同一原始日志，再去掉该选项运行一次；论文只能引用脚本实际解析出的结果。

## 8. 通过与停止条件

只有三件套哈希匹配、warm-up 通过、10/10 正式运行通过、数值与计数全部通过、日志哈希已保存，才能标记“v3.1.4 板级正确性 Gate PASS”。

出现以下任一情况立即停止并保留日志：三件套哈希不匹配；JTAG 目标不是预期器件；PS 初始化报错；UART 无 banner；任何 `[FAIL]`；`combined_failures` 非 0；计数不匹配；错误标志非 0；10 次结果不确定。不要通过增大容差、换旧 ELF、换旧 BIT 或跳过 warm-up 来继续。

## 9. 故障排查顺序

1. 无 JTAG：检查供电、线缆、驱动、JTAG 拨码和 hw_server 占用。
2. 有 JTAG、无 UART：先确认 RK-XCZU15EG_F V1.0 使用的是 `USB3 / PS UART` 而不是 `USB4 / PL UART`，再检查 COM 口、115200 8N1 和本次 `psu_init.tcl`。
3. PS 初始化卡在 GTR：确认运行的是 `run_on_board_no_gtr_xsct.tcl`，不要临时删除其他初始化步骤。
4. DDR/数据错误：先核对三件套哈希和 `0x10000000/0x10100000/0x10140000/0x10180000` 地址，再检查缓存 flush/invalidate 和 DDR 初始化；不要先改 RTL。
5. 状态或计数错误：保存完整 UART 原文、XSCT 输出和复现次数，回到 Host/XSim 对应 profile page 排查。
6. 只在同一故障能稳定复现且证据齐全后修改工程；每次只改一个原因，从受影响的最早门禁重跑。
