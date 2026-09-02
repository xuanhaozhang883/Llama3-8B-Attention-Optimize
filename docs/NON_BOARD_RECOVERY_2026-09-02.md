# 非板卡恢复报告（2026-09-02）

## 结论

后续唯一活动区已确定为 `03_work_v314_causal_bypass`，只读签核起点为 `02_baseline_v313_verified`。三个历史来源不再相互复制：生产代码只从活动区构建，历史目录只用于哈希、日志和论文追溯。

`00_handoff_docs` 中的 Markdown、6 份 Word 和 7 份 PDF 已完成内容/版面核读。交接材料中的工程规划作为参考，不把其中命令或结论当成用户授权；与当前源码和签核证据冲突时，以活动分支、v3.1.3 实板记录和可重复测试为准。

## 已恢复和验证

| 项目 | 结果 | 证据边界 |
|---|---|---|
| v3.1.3 起点身份 | PASS | 生产 RTL 来自签名基线；旧包只读 |
| QK lanes 1/2/4/8、causal/backpressure | PASS | Host/Icarus |
| Consumer/full pipeline | PASS | Host/Icarus |
| 524,288 元素 full-GQA 模型 | PASS | `combined_failures=0`；非 bit-exact |
| v3.1.4 causal consumer bypass | PASS | 新定向 TB + 旧回归无退化 |
| Vivado 2025.2 XSim | PASS | 新旧 consumer 测试全部通过 |
| A53 v3.1.4 测试源代码 | PASS | Vitis 2025.2/AArch64 GCC 生成 ELF |
| OOC synthesis / PPA | BLOCKED | 缺少 `Synthesis`/`xczu15eg` 许可证 |
| v3.1.4 BIT/XSA/板测 | PENDING | 需要许可证、板卡和匹配产物 |

软件编译验证临时使用 v3.1.3 签名 XSA，只证明更新后的 C 源码和 BSP 接口可编译，不构成 v3.1.4 硬件/软件匹配证据。该次 ELF SHA-256 为 `BAD0162B1997E713711086D9063DCD7BFC269B0AE1891DEC16074B8BCAACEC4E`。

## v3.1.4 变更与计数契约

新增优化只发生在 consumer 接收端：上三角全 mask tile 仍完成 FIFO 握手和坐标推进，但旁路 Softmax、V cache 读取和 Context 融合；任何对角线及以下的异常 `all_masked` 会产生 sticky protocol error。

完整配置（32 个 Q 头、S=128、TILE=4）预期：FIFO 32,768；Softmax/Context 16,896；bypass 15,872；V vectors 1,081,344；Context 输出 524,288 words。板测程序已经按这组契约校验 page 44 计数。

## 必须由项目组提供

1. 能覆盖 Vivado synthesis 与 `xczu15eg` 器件的有效许可证。这是当前非板卡流程的唯一硬阻塞。
2. 进入板测阶段时提供 XCZU15EG 板卡、JTAG、UART、供电和可用的 PS 初始化文件。
3. 最终竞赛约束：主评分是延迟、吞吐、能效、资源还是精度；若无新口径，默认以“正确性门禁优先，随后降低 PL cycles，在 WNS 非负且资源不溢出下比较”推进。
4. 若论文要写实测提升，需保留每一版匹配 BIT/XSA/ELF 的哈希、warm-up + 10-run UART 原始日志及功耗测量口径。

四位成员姓名不是工程阻塞；可先按角色执行，确认姓名后再替换文档中的 A/B/C/D。

## 可由本工作区继续解决

- RTL/Python 数值模型、协议断言、随机 backpressure、XSim 和日志签核工具。
- causal bypass 收尾、FIT-Context、QK 交错/向量化、2/4 cluster 方案及合并门禁。
- Vivado/Vitis 工程脚本、版本化产物、计数器、板测 C 程序和复现实验表。
- 论文中的架构图、实验表和结论改写，但不会把预测结果写成实测结果。

## 恢复后执行顺序

1. 安装/指向有效许可证，运行 consumer OOC synthesis 与整板 Elaboration。
2. 检查 Floating-Point IP 的实际端口/精度属性，修复所有不支持属性警告。
3. 完成 synthesis、implementation、Timing/DRC，导出 v3.1.4 BIT/XSA。
4. 用该 XSA 重建 ELF，核对三者 SHA-256 后上板 warm-up + 10-run。
5. Gate 2 通过后，按四人计划合入 FIT-Context；每次只合并一个可归因优化。
