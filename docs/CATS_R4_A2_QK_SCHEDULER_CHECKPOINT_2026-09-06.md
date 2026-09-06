# CATS-R4 A2 QK 调度器本地检查点（2026-09-06）

状态：LOCAL CHECKPOINT / NOT READY

本记录只描述当前工作树新增的 32-key-lane、R=16 QK 发射调度器候选，不代表 A unit READY、C2 READY 或 board-ready。实现未加入 scripts/source_manifest.tcl，也未连接生产 cluster wrapper。

## 本次实现

- RTL：rtl/core/bc/qk/cats_r4_qk_32lane_scheduler.sv
- TB：tb/tb_cats_r4_qk_32lane_scheduler.sv
- 可重复验证：tests/run_cats_r4_qk_32lane_scheduler_vivado.ps1
- 单个 job 覆盖一个 16-row Q window、一个 32-key block 和 d=0..127。
- Q/K request 使用冻结的 context tag；Q/K response 按冻结的两拍、无 response backpressure 语义接收。
- MAC 通过独立 tagged valid/ready service 接口连接，调度器不假设浮点 IP 固定延迟；MAC completion 可变延迟返回，但必须回显 epoch/group/head/row/key-block/context/d。
- causal 无效 key 不进入 mac_lane_valid；矩形 slab 的空槽与 lane bubble 分开计数。
- valid 被反压时，Q/K/MAC payload 与 tag 保持稳定；done descriptor 在 done_ready=0 时保持稳定。
- 宽 Q/K 缓存不做 reset 清零，Vivado 可推断 LUTRAM；valid/ownership 位仍在 reset/clear 时清除。

## 验证结果

从空输出目录运行：

    tests/run_cats_r4_qk_32lane_scheduler_vivado.ps1

输出根：

D:/Vitis/FPT/c2_qk_sched_verify_20260906_r1

结果：

    [PASS] CATS-R4 R16/32-lane QK scheduler XSim and 150 MHz OOC

XSim 覆盖：

- 完整 16-row tile；
- 全 causal 跳过 tile；
- 5-row short tile；
- 随机 Q/K request backpressure；
- 随机 MAC issue backpressure；
- 2..9 cycle 可变 MAC completion delay；
- completion tag、d 顺序、first/last、causal lane mask；
- done backpressure payload stability；
- 非法 group/head 启动门禁；
- duplicate/missing/context reuse 检查。

Icarus 同一测试也通过：

    PASS: CATS-R4 R16/32-lane QK scheduler tags, causal mask, stalls, and counters

完整 16-row tile 的定向 counter：

- Q requests = 2,048；
- K requests = 2,048；
- MAC steps issued/completed = 2,048；
- 有效 MAC = 17,408；
- causal lane bubbles = 48,128；
- 协议错误 = 0。

这些是单个 16-row × 32-key block × D=128 job 的计数，不是 full workload aggregate。

## OOC 证据

Vivado 2025.2，器件 xczu15eg-ffvb1156-2-i，150 MHz core_clk，输出根：

D:/Vitis/FPT/c2_qk_sched_verify_20260906_r1/ooc

- synth_design：0 errors，0 critical warnings；
- setup WNS：+2.543 ns；
- setup failing endpoints：0；
- pulse-width failing endpoints：0；
- CLB LUT：1,738；
- CLB registers：1,397；
- Block RAM tile：0；
- DSP：0；
- URAM：0。

这是 synthesis-only OOC；没有 place/route、hold closure、CDC/reset closure、full-board timing/DRC、BIT/XSA/ELF 或板测证据。

## 尚未完成的 A2 门禁

当前调度器不是完整 A2，仍缺：

- 真实 FP32 multiply/add datapath 与既定数值/舍入边界；
- 32-lane QK accumulator 的 R=16 context service；
- score/max row slab 写接口、mask/last/epoch 输出；
- score-by-score、lane 1/2/4/8 equivalence；
- full-size aggregate 有效 QK MAC 33,816,576 的闭合；
- full-size combined numerical regression；
- reset/clear 与 memory-service 集成后的完整异常注入；
- A2 READY marker/commit。

因此不得据此启动 B2/B3、A3 cluster integration、production manifest、full-board build 或板测。下一逻辑步骤是围绕该调度器接入真实 FP32 MAC/accumulator，再验证 score/max commit；B Softmax/PV 和完整 C memory-service 仍未 READY。
