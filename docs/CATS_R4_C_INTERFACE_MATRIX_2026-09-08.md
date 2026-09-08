# C 侧接口差异矩阵

审计基线：`CATS_R4_INTERFACE_COMMIT`（IF_V1）、`CATS_R4_INTERFACE_V2.md`、
`CATS_R4_INTERFACE_V3.md`。对象：`cats_r4_qkv_axi_bank_bridge.sv`。

| 条款 | 冻结要求 | 当前源码证据 | 状态 | 放行证据 |
|---|---|---|---|---|
| Q mapping | 4 banks，`bank=d[1:0]` | q bank select 使用 `q_req_d[1:0]` | PARTIAL | readback TB 覆盖 4 banks |
| K mapping | 32 key banks，lane=`32*block+i` | K write/read arrays 存在 | PARTIAL | 全 key block readback |
| V mapping | 32 feature banks，lane=`32*block+i` | V write address/feature select 存在 | PARTIAL | 全 feature block readback |
| response latency | 接受后 N+2 core edges | p0/p1 标记 + XPM latency 参数 | NOT PROVEN | 真实 XPM 连续请求 timestamp |
| response backpressure | response 无 ready | 端口无 ready | PASS (shape only) | 连续请求无丢失/覆盖 |
| buffer switch | 切换期间 `req_ready=0` | ready 直接由 `active_valid` 驱动 | FAIL/PENDING | 状态机或切换负向 TB |
| lifecycle | EMPTY→FILLING→READY→ACTIVE→EMPTY | 本模块仅 descriptor active/done | MISSING | owner state machine + assertions |
| active write | active buffer 写入必须阻止 | wr path 未见 active-buffer 输入仲裁 | MISSING | active-write negative test |
| epoch | 旧 epoch 丢弃并计数 | descriptor token match；无 v3 epoch_drop | PARTIAL | abort/reset epoch-drop counter |
| group/head/beat | 全字段稳定且连续 | descriptor match 检查存在 | PARTIAL | malformed token matrix |
| 4 KiB boundary | burst 不跨 4 KiB | beat endpoint，不含 burst splitter | MISSING | AXI address/length split TB |
| short tail | descriptor 支持通用短尾 | expected last 固定 Q511/KV4095 | FAIL/PENDING | short descriptor TB + count |
| v3 weight slab | FP32 weight、row_commit、pv_row、release | 端口不存在 | MISSING | 独立 v3 memory service |
| counters | DDR/counters 闭合且错误为 0 | 仅 Q/K/V accepted + protocol errors | MISSING | full normal-load counter report |
| CDC | reset/async FIFO/pointer clear | CDC ownership outside module | MISSING | CDC FIFO reset test + OOC |

## 结论

当前 bridge 只能作为 IF_V1 AXI beat-direct 候选和 protocol-only checkpoint，
不能标记为 C2 READY，也不能代替 v3 Accuracy weight memory service。任何 READY
报告必须同时引用本矩阵、源码 SHA、测试日志和工具版本。
