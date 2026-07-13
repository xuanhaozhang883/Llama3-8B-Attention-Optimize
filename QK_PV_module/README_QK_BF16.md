# QK BF16 RTL 验证版

## 你要复制到工程的位置

把 `rtl/` 里的文件复制到你的：

```text
QK乘法器/rtl/
```

把 `sim_data/` 里的文件复制到你的：

```text
QK乘法器/sim_data/
```

建议先只加入这几个新的 RTL 文件，不要先混用旧的 int8 pe/array：

```text
bf16_to_fp32.v
fp32_to_bf16.v
fp32_mul_ip.v
fp32_add_ip.v
qk_dot_product_bf16_serial.v
tb_qk_dot_product_one.v
tb_qk_dot_product_many.v
```

## 需要创建的 Vivado Floating Point IP

### floating_point_0

用途：q * k

配置：

```text
Component Name: floating_point_0
Operation: Multiply
Precision: Single
Interface: AXI4-Stream
TLAST/TUSER/TKEEP: 不勾
```

### floating_point_1

用途：acc + product

配置：

```text
Component Name: floating_point_1
Operation: Add/Subtract
Precision: Single
Interface: AXI4-Stream
TLAST/TUSER/TKEEP: 不勾
```

如果有 Add/Subtract 的细分选项，选择固定 Add。

### floating_point_2

用途：acc * 1/sqrt(128)

配置：

```text
Component Name: floating_point_2
Operation: Multiply
Precision: Single
Interface: AXI4-Stream
TLAST/TUSER/TKEEP: 不勾
```

生成后点：

```text
Generate Output Products
```

## 推荐仿真顺序

### 第一步：单个 score

Simulation Sources 里把顶层设为：

```text
tb_qk_dot_product_one
```

Run Behavioral Simulation。

期望看到：

```text
[PASS]
```

### 第二步：多个 score

Simulation Sources 里把顶层设为：

```text
tb_qk_dot_product_many
```

默认 `MAX_TESTS = 16`，先测前 16 个 score。

通过后可以把 testbench 里的：

```verilog
parameter MAX_TESTS = 16;
```

改成：

```verilog
parameter MAX_TESTS = 65536;
```

全量测试 4*128*128 个 score，但会比较慢。

## 如果 $readmemh 路径报错

把 testbench 里的相对路径：

```verilog
$readmemh("../sim_data/q_vec.hex", q_mem);
```

改成你电脑上的绝对路径，例如：

```verilog
$readmemh("D:/学习/VScode项目/Llama3-8B/QK_PV_module/sim_data/q_vec.hex", q_mem);
```

Vivado/Verilog 字符串里推荐用 `/`，不要用反斜杠。

## 这个版本的设计原则

这版是先保证数值正确的稳妥版：

```text
BF16 输入
-> 转 FP32
-> FP32 乘法
-> FP32 累加 128 次
-> 乘 1/sqrt(128)
-> FP32 转 BF16 输出
```

不要用旧的 `bf16_multiplier.v` 直接放到 PE 里累加，因为它的乘法结果已经转回 BF16，再累加误差会变大。
