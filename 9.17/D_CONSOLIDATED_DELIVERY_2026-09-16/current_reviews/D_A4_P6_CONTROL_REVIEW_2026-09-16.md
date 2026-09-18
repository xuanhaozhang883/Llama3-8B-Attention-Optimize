# D 独立复核：A4 P6 双集群控制单元

日期：2026-09-16  
复核对象：`codex/a-cats-r4-a4-2cluster`  
分支头：`5299d9430523d4d7dbd1231e33434f331ef8f8f0`  
精确证据源：`982f98e2e631b8df82119e5fcbd3a2f576d2dcd9`

## 结论

**接受 A4 P6“可复用控制单元”作为单元级协议证据；不接受为真实 N=2 集成、性能、OOC、实 IP 或整板完成证据。**

正式状态：`P6_CONTROL_UNITS_READY / N2_INTEGRATION_NOT_READY`。

这项增量可以关闭 D 对下列控制单元的文档复核：

- 四源 event join 的并发接收、锁定仲裁、反压稳定性和计数；
- 两集群 telemetry 的相干快照、归约、故障门控和 clear；
- 两集群 transaction fanout 的异步 start、单次错误报告、epoch/mode 检查和 drain 解锁；
- 双 adapter 控制平面的静态分组、独立反压、完成保持、错路由隔离和守恒计数。

## 证据核对

远端 checkpoint 和 `evidence_index.json` 一致声明：

| 项目 | 证据结果 |
|---|---|
| event join | `clusters=4 emitted=3 locked_stalls=3 simultaneous=1` |
| telemetry | `clusters=2 first=100 last=900 groups=8 active=1500` |
| transaction fanout | 异步 start、反压稳定、drain gate、epoch/mode/clear 检查通过 |
| dual-adapter control plane | `clusters=2 groups=2 jobs=64 retires=64` |
| exact unit suite | `status=PASS, exit_code=0, timed_out=false, dirty=false` |
| 证据类别 | `unit_protocol_model_not_real_ip` |

证据索引给出了 RTL、TB、运行脚本和 stdout/source manifest 的 SHA256。D 接受这些哈希作为远端归档身份记录；本次未把未跟踪的 `artifacts/local_archive/...` 原始归档伪装成本地复跑结果。

## 尚未通过的门槛

以下内容仍然缺失，因此 D 不能签署 A4-2 或最终 Dense 完成：

1. 两个真实 A3 实例与两个独立 C service 的数据面连接；
2. 真实 start/event/halt/drain 全链路；
3. peer stall 下的数据面前进性；
4. 完整 workload 的输入、job、retire、Context 守恒；
5. C 对 canonical output 容量、提交仲裁与最终 Context 接收边界的冻结；
6. 相同输入/模式/时钟/工作量下的 N=1 与 N=2 实测性能；
7. N=2 OOC/资源/时序、real-IP 数值验证和新版整板验证。

## 对 D 状态的影响

- 新增完成：`D-A4-P6-CONTROL-REVIEW`。
- 保持开放：`A4-CANONICAL-OUTPUT`、真实 `N=2` 集成、性能门槛、资源/OOC、real-IP、板卡签核。
- 不得把模型预测或控制面 unit PASS 写成 `speedup >= 1.6` 的测量结果。

## 远端依据

- `docs/CATS_R4_A4_P6_CONTROL_CHECKPOINT.md`
- `artifacts/a4_p6_control_20260915/evidence_index.json`
- `docs/CATS_R4_A4_INTEGRATION_REQUESTS.md`

