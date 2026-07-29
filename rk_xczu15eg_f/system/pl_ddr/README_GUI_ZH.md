# RK-XCZU15EG-F 独立 PL DDR4 校准与内存自测工程

本目录用于从板卡厂商 `10_DDR4_TEST` 资产重建 Vivado 2025.2 工程。工程目标器件固定为 `xczu15eg-ffvb1156-2-i`，顶层采用厂商的 `top.v + mem_burst.v + mem_test.v + ddr4.xci`，不包含 PS，也不运行仿真。

## 一次性生成工程

先在仓库根目录准备本地厂商资产：

```powershell
powershell -ExecutionPolicy Bypass -File .\rk_xczu15eg_f\system\scripts\prepare_vendor_assets.ps1 `
  -VendorRoot "D:\00game\FPGA\XCZU15EG参考手册\1.RK-XCZU15EG V1.0开发板网盘资料"
```

然后创建 Vivado 工程：

```powershell
& "D:\Vitis\2025.2\Vivado\bin\vivado.bat" -mode batch `
  -source .\rk_xczu15eg_f\system\pl_ddr\create_pl_ddr_project.tcl
```

生成后的 GUI 启动文件：

`rk_xczu15eg_f/system/vx/pl_ddr/rk_pl_ddr.xpr`

双击该 `.xpr`，或在 Vivado 2025.2 的 **File → Open Project** 中选择它。

## GUI 中应检查的内容

1. **Project Settings → General → Project device** 必须为 `xczu15eg-ffvb1156-2-i`。
2. Sources 顶层必须为 `top`，并能看到 `mem_test`、`mem_burst` 和 `ddr4` IP。
3. **Reports → Report IP Status** 中 DDR4 IP 不应处于 locked 状态。
4. 运行 **Synthesis** 后，在 **Open Synthesized Design → Set Up Debug** 中选择 `init_calib_complete`、`error`；这些信号已在厂商 RTL 中标记为 `MARK_DEBUG`。需要时也可加入 `heartbeat` 和握手信号。
5. 完成实现并生成 bitstream 后，在物理板上观察：
   - `init_calib_complete == 1`：DDR4 校准完成；
   - `error == 0`：当前运行期间未发现读回比较错误。

## 必须保留的硬件风险说明

厂商 XCI 中的内存型号字符串是 `MT40A512M16HA-083E`，项目资料记录的板上颗粒标识是 `LY-062E`。这两个字符串并不相同，本工程只复用了该精确板卡随附工程，未证明两者的电气和时序等价性。

因此，成功生成 XPR、IP 输出产品、综合、实现或 bitstream 都不能单独记为 `HARDWARE_PASS`。只有在 RK-XCZU15EG-F V1.0 实板上稳定观察到校准完成且自测无错误，才可更新硬件状态；在此之前统一保持 `HARDWARE_PENDING`。

## 约束处理说明

厂商 `pin.xdc` 前半部分包含旧实现会话导出的 ILA 命令和大量实现层级网名，直接迁移到 Vivado 2025.2 容易失效。生成脚本会：

- 把五个厂商输入复制到生成工程内部，避免升级 IP 时改写哈希审计过的本地缓存；
- 从厂商 XDC 中机械提取 `PACKAGE_PIN` 和显式 `IOSTANDARD` 命令；
- 排除旧的 ILA/debug-hub 命令；
- 由 DDR4 IP 生成 DDR 电气及时序约束。

原始厂商 XDC 仍保存在生成工程的 `vendor_native/pin.xdc` 中作为审计快照，但不会加入默认约束集。
