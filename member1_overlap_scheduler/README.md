# 成员1：GQA跨Group调度器第一阶段交付

## 1. 文件用途

```text
rtl/gqa_overlap_scheduler.sv
    双Bank跨Group波前调度器

tb/tb_gqa_overlap_scheduler.sv
    自检Testbench，包含不同B+C/Buffer/PV延迟和启动背压

scripts/add_and_run_scheduler_tb.tcl
    在现有Vivado工程中添加并运行独立Scheduler仿真
```

本阶段只验证调度控制，不接真实RoPE、QK、Softmax和PV计算模块。

## 2. Scheduler接口约定

每个Bank的生命周期：

```text
EMPTY -> FILLING -> READY -> DRAINING -> EMPTY
```

关键完成信号：

```text
bc_group_done
    B+C内部计算完成

fill_complete
    最后一个B+C输出Beat已经成功写入Bank

pv_done
    该Group最后一个Context输出已经完成ready/valid握手
```

只有同时收到`bc_group_done`和`fill_complete`后，Bank才会进入READY。

## 3. 在Vivado中运行

### 方法A：使用Tcl

1. 打开当前Attention Vivado工程。
2. 打开Tcl Console。
3. 执行：

```tcl
source D:/你的路径/member1_overlap_scheduler/scripts/add_and_run_scheduler_tb.tcl
```

成功时必须看到：

```text
[PASS] GQA overlap scheduler self-check
B+C launches          = 8 / 8
PV launches           = 8 / 8
Group completions     = 8 / 8
Overlap cycles        > 0
Error bitmap          = 00
```

### 方法B：图形界面

Design Sources加入：

```text
rtl/gqa_overlap_scheduler.sv
```

Simulation Sources加入：

```text
tb/tb_gqa_overlap_scheduler.sv
```

Constraints不需要加入任何文件，因为这是纯行为控制仿真。

将Simulation Top设置为：

```text
tb_gqa_overlap_scheduler
```

然后执行：

```text
Run Simulation -> Run Behavioral Simulation -> Run All
```

## 4. 第一阶段验收

- B+C启动8次；
- PV启动8次；
- Group按照0到7顺序完成；
- B+C和PV至少有一个周期同时active；
- 同一Bank不能同时被读写；
- `done`只产生一个周期；
- `error_bitmap`等于`00`；
- 仿真最终打印`[PASS]`。

## 5. 接真实顶层前必须确认

必须从GitHub最新版取得：

```text
attention_system_with_rope_pv_top.sv
当前黄金模型TB
当前真实PV顶层
当前串行Group控制器
```

然后把原来的串行控制器替换为`gqa_overlap_scheduler`，不要修改已经通过验证的RoPE、QK、Mask、Softmax和PV算术模块。
