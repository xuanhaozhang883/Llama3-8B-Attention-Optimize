# 仓库唯一权威路径与清理规则

状态：自 2026-09-09 起适用。

目标：同一种事实只保留一个权威来源，其他文件必须明确是派生物、测试、报告或历史研究。

## 1. 唯一入口

| 内容 | 唯一权威路径 | 说明 |
|---|---|---|
| 当前项目配置 | project_config.json | 器件、规模、地址、v3.1.4 参数 |
| 生产 RTL 清单 | scripts/source_manifest.tcl | 只有这里列出的 RTL/mem/XDC 能进入当前生产构建 |
| 板级 RTL 顶层 | rtl/board/attention_board_top.sv | 当前 v3.1.4 生产顶层 |
| 数值签核模型 | python/flash_attention_tile_model.py | 当前唯一正式 numerical gate 入口，包含 RTL 语义和独立数学参考 |
| 数值回归入口 | tests/run_v31_flash_numerical_model.ps1 | 调用唯一数值模型，不另写一套计算 |
| 冻结 Q 输入 | vitis/data/q_before_rope_bf16.hex | 32×128×128 BF16 |
| 冻结 K 输入 | vitis/data/k_before_rope_bf16.hex | 8×128×128 BF16 |
| 冻结 V 输入 | vitis/data/v_bf16.hex | 8×128×128 BF16 |
| 冻结期望 Context | vitis/data/attn_out_per_head_bf16.hex | 32×128×128 BF16 |
| 板测 header | vitis/src/fpt_golden_vectors.h | 由四份 HEX 确定生成的派生物，不是另一套 golden |
| header 生成器 | python/generate_golden_header.py | 构建前生成，输出固定 LF，跨平台字节一致 |
| 外部向量导入器 | python/prepare_golden_vectors.py | 只导入/量化外部 NPY，不是 golden model |
| ROM | mem/ | sin、cos、exp LUT 的唯一生产位置 |
| 板测日志签核 | python/signoff_v31_board_log.py | 解析和签核日志，不重新定义数值模型 |
| 构建报告摘要 | reports/ | 标明来源 commit/build，不能冒充板测 |
| 硬件产物 | export/ 与 artifact manifest | BIT/XSA/ELF 必须有同源身份链 |

## 2. Golden/reference 分类

### 正式签核

python/flash_attention_tile_model.py 是当前唯一正式数值签核实现。发布结论必须通过 tests/run_v31_flash_numerical_model.ps1 或等价 CLI，并绑定输入哈希和输出 JSON。

其中 RTL-exact 路径复现项目算术边界，mathematical_reference 提供独立数学对照。两者属于同一受控入口的两种模式，不是互相竞争的 golden model。

### 冻结向量

vitis/data 下四份 HEX 是当前板测数据集的唯一仓库内字节源。fpt_golden_vectors.h 只是裸机编译用 C 表示。修改 HEX 后必须重生成 header 并重走输入、数值、软件和板测身份链。

### 历史研究

docs/architecture_study_20260905 下的脚本与 JSON 记录候选研究。它们保留原始哈希，但不参与生产构建，不能单独签核当前 CATS-R4 RTL。

### CATS-R4 Accuracy

CATS-R4 Accuracy 的正式硬件实现和独立验证尚未 READY。在队长批准前，不新增第二个 golden 目录或复制模型。新能力优先扩展唯一模型的显式模式；若确需替换入口，必须同一提交更新本文、回归入口、输入哈希和迁移验证。

## 3. 目录职责

| 目录 | 可以放 | 不可以放 |
|---|---|---|
| rtl/ | 生产或候选 RTL，按职责分层 | Vivado 生成目录、旧工程整体复制 |
| tb/ | RTL testbench、受控模型 | production 顶层副本 |
| tests/ | 可复现回归入口和检查器 | 手工截图、无来源临时输出 |
| python/ | 唯一数值模型及辅助工具 | 多套同义 golden 实现 |
| scripts/ | 构建、清单、约束、工具自动化 | 本机许可证和临时绝对路径 |
| mem/ | 生产 ROM | 根目录副本 |
| vitis/data/ | 冻结板测输入/期望输出 | build cache、workspace |
| vitis/src/ | 裸机源码和确定性派生 header | ELF、BSP、workspace |
| reports/ | 小型结构化摘要和说明 | 未标身份的大型临时报告 |
| export/ | 受 manifest 管理的候选产物 | 随手复制的旧 BIT/XSA |
| artifacts/ | 原始日志和身份 manifest | 会覆盖历史的同名输出 |
| docs/architecture_study_20260905/ | 只读研究证据 | 生产签核入口 |

## 4. 禁止提交

- 根目录工作区 ZIP 或包含 .git 的自备份。
- .Xil、Vivado/Vitis workspace、缓存、临时仿真快照。
- 根目录 cos_bf16.hex、sin_bf16.hex、exp_lut_q15.mem 副本。
- .jou、无身份的 .log、许可证、用户绝对临时路径。
- 同一 RTL、模型、golden 或 ROM 的第二份方便副本。

禁止无选择执行 git clean -fdX，因为 export、reports 和本地原始日志可能含尚未归档但必须保留的证据。

## 5. 历史文档

历史 checkpoint、状态快照和方案文档可以保留，但必须在 docs/README.md 标为历史/证据，不能与当前入口并列。Git 历史可恢复被删除的误导副本，不再保留整仓 ZIP。

## 6. 自动检查

运行 python tests/check_repository_hygiene.py。

检查器验证唯一入口存在、禁止项未被 Git 跟踪、根目录无 ROM 副本，并在临时目录重建 fpt_golden_vectors.h 后逐字节比较。

## 7. 本轮清理决策

保留：

- python/flash_attention_tile_model.py；
- vitis/data 四份 HEX；
- vitis/src/fpt_golden_vectors.h（派生、构建前重建并检查）；
- docs/architecture_study_20260905（历史研究证据）；
- export/reports/artifacts 中有身份链的结果；
- 当前用户未提交文件。

移除：

- Git 跟踪的 03_work_v314_causal_bypass.zip：约 16.6 MB，内部包含 .git，是可由 Git 历史恢复的仓库自备份；
- 已审计且可重建的 .Xil、dfx_runtime.txt 和根目录三份重复 ROM。

暂不移除：

- 根目录 Vivado 日志：虽被忽略且可再生，本轮保守保留，确认无调试价值后再做第二批清理；
- 任何 BIT/XSA/ELF、实现报告、原始 UART 日志；
- 尚在工作的未提交文档。
