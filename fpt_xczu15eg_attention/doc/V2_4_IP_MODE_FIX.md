# v2.4 Block Design综合模式修复

## 现象

路径修正版已经正确使用 `_fpt_v24_build` 中的新BD和wrapper，但
`synth_design -rtl` 仍报：

```text
module 'design_1_axi_gpio_ctrl_0' not found
```

日志同时表明 `generate_target all` 已完成 `axi_gpio_ctrl` 的生成。

## 原因

Vivado默认以Out-of-Context per IP方式生成Block Design。快速检查使用
`synth_design -rtl`，不会读取子IP的OOC DCP，因此新建的AXI GPIO在该检查中
表现为缺失模块。

## 修复

新脚本在重新生成BD output products前设置：

```tcl
set_property SYNTH_CHECKPOINT_MODE None $bd_obj
```

这会让Block Design及其子IP参加顶层Global Synthesis。

## 使用

先运行：

```tcl
source scripts/check_rtl_elaboration_ipfix.tcl
```

通过后运行：

```tcl
source scripts/build_profile_foreground_ipfix.tcl
```

旧的两个无 `_ipfix` 后缀的脚本保留作问题复现和版本对照，本修正版请勿使用。
