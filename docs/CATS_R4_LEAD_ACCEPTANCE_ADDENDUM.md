# 队长验收补充与纠正

日期：2026-09-08。适用于本目录 RELEASE_GATE、C_BRIDGE_AUDIT、C_INTERFACE_MATRIX。
这些文件是验收清单，不是实现通过报告。以下澄清优先于其中不准确的概括。

## 责任和阶段

- A 负责 QK score/max、score formatter、score 行交接；不是 Accuracy weight formatter 的生产者。
- B 负责 Softmax exp/sum/reciprocal、FP32 weight 生成及 PV。C 负责 weight 存储、所有权和读服务。
- C2 入口需要上游 READY 和明确集成基线；full-board synthesis/implementation/Timing/DRC 是进入该阶段之后的验收，不能要求它们先完成才能进入 C2。
- 三人团队的独立验证由队长安排交叉复核，D 是验证职责，不要求新增成员。

## bridge 审计范围

当前桥接文件头已写 IF_V1。历史 IF_V2 注释变化不能证明逻辑已兼容任何版本。
矩阵中的 MISSING 只表示此 bridge 未实现，不表示整个仓库没有相应模块。
已找到的上层候选包括：

| 功能 | 源码 | 尚需证据 |
|---|---|---|
| AXI 边界/短尾 | rtl/core/cluster/cats_r4_axi_burst_splitter.sv | 地址、长度、4 KiB split 和总 beat 守恒 |
| DMA group | rtl/core/cluster/cats_r4_dma_group_scheduler.sv | 与 bank completion token 对接 |
| 独立 Q slab | rtl/core/cluster/cats_r4_q_slab_dma_controller.sv | Q/KV 独立 selector 和 retire/outstanding |
| CDC | rtl/core/cluster/cats_r4_async_fifo.sv、cats_r4_output_cdc.sv | 异步时钟、单边 reset、pointer/旧 epoch 清理 |
| output | rtl/core/cluster/cats_r4_output_reorder_serializer.sv | 满/反压、payload/tag、保序写回 |

bridge 固定 512/4096 beats 是逻辑 slab 填充长度，不能仅据此判定 AXI burst 不支持短尾。
必须分别验证 burst 层短尾与整个 slab 完整性。buffer switch、active-write 等本模块未保证的条件，
应追踪上层 owner/CDC 合成边界；在证明拒绝非法传输之前仍 NOT READY。
本轮没有运行上述模块的 RTL 回归，也没有证明其连接已闭合。

## 接收 B2 后的顺序

1. 保存 branch/head SHA、接口 tag、dirty 状态、文件/输入/log 哈希。
2. 检查端口差异：score16、Accuracy weight32、mode/token/last、N+2 无回压读。
3. 运行成员给出的 Python 与 RTL 命令；没有 Vivado 的成员由 C 集中运行并回传同一源 SHA 的日志。
4. 将数值模式和具体失败 seed 写入 DELIVERY；不以历史 JSON 代替新实现回归。
5. 证据通过后才更新对应单元 READY；缺源码或未运行保持 NOT READY。
