# CATS-R4 当前协作规范与队长决议

队长兼C负责人：当前用户。2026-09-08起用于CATS-R4；旧TEAM_4_COLLABORATION_PLAN
关于A总集成/C做QK/D做banking的角色分配为历史方案，不再作为当前分工。

| 负责人 | 当前责任 | 本轮交付 |
|---|---|---|
| A | QK、scheduler、score/max、计算cluster内部集成 | 补score/max ownership和full计数；按v3消费Q slab及数值模式 |
| B | Softmax、exp/sum/reciprocal、PV及数值参考 | 上传B2 checkpoint；实现Accuracy FP32 weight；补B2后进入B3 |
| C兼队长 | banking、DMA、CDC、输出、board、工具构建；接口与主线最终决定 | 冻结v3；接收成员候选并集中跑Vivado；完成C memory验证 |
| D | 独立参考、阈值签核、回归与板测证据 | 校验报告来源、独立数值/协议检查、产物身份链 |

截图列出的member-b-cats-r4、B2文件属于B职责（无论转发者是谁）。截图中的6项Python、
Compatibility RTL、软件full通过等均暂记为成员报告，待源码与日志到达后复核。
当前未发现远端member-b分支，不能声称已经审查该未提交工作树。

## 分支和交接

统一共享集成分支为codex/cats-r4-local-integration；各成员从队长指定完整SHA建立独立分支，
建议codex/a-qk-*、codex/b-softmax-*、codex/c-memory-*、codex/d-validation-*。
已有member-b-cats-r4可继续使用，无需为改名重做工作。每人独立checkout/worktree。
成员在个人分支保存、推送checkpoint；即使NOT READY也允许提交，commit标题和DELIVERY须明确。
“未达READY不得提交任何代码”停止使用：READY控制正式集成，不阻止分享源码供别人验证。
禁止互相覆盖文件或无证据修改接口版本注释；跨owner改动先给最小diff及理由，由队长协调。
主线合入由队长按依赖完成；不force-push共享分支，不移动已发布tag。

交付必填：owner、base/head SHA、分支、消费的interface tag、文件清单、复现命令、
工具/器件、输入和报告hash、预期/实际counter、数值模式/误差、PASS/FAIL/未跑、
失败seed、日志相对路径、已知问题、下一个依赖。截图只能辅助说明，不能代替源码或日志。
临时Vivado/Vitis工程和大产物按manifest归档，不混入源代码提交；原始失败证据保留。

## 状态与并行工作

分开记录工作状态（NOT STARTED/IN PROGRESS/BLOCKED）与签核状态（NOT READY/READY）。
BLOCKED必须写明哪项外部依赖，其他可执行工作继续。READY必须注明单元/OOC/整板级别。
A做QK、B做Softmax/PV、C做memory/CDC/output单元可以并行；依赖冻结接口和替身驱动验证。
只有整合/整板门禁要求相应上游READY，不要求等A/B READY才允许C写单元或测试。

队友没有Vivado/Vitis 2025.2时，把源码、TB、工具参数与失败记录提交给C集中验证。
成员状态记“待C工具验证”，C返回源SHA、工具版本、日志和资源/时序结果；未跑不能标PASS。
自制IP模型的PASS仅证明模型范围内的行为；改动生产IP latency前须查厂商模型并做连续请求验证。
当前9c89ed2中的XPM latency=1修改仅有自制模型证据，禁止以此认定真实XPM错位已修复；C须复审。

## 本次具体安排

1. B取docs/architecture_study_20260905两份JSON，执行tests/check_cats_r4_lead_release.py。
2. B把截图中的五个B2文件、TB和日志以NOT READY checkpoint推到个人分支，交完整SHA。
3. A/B/C按CATS_R4_INTERFACE_V3_COMMIT实现接口；先对照精确端口，不依据旧提示词混用拓扑。
4. B继续Accuracy exp/sum/reciprocal；C准备该SHA的XSim/OOC验证；D复核full/stress。
5. A/B/C单元与计算wrapper签核后进入150 MHz全板；随后才按证据推进扩展和升频。

本决议不宣称队友已经确认或执行。队长发出后，各成员下一次DELIVERY记录收到的版本即可。
