# D2 CATS-R4 独立验证与 Telemetry 契约：执行步骤与交付清单

日期：2026-09-08  
负责人：D（独立验证）  
阶段：D2  
接口基线：`CATS_R4_INTERFACE_V3_COMMIT`  
接口提交：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`  
前置状态：D1 已完成；CATS-R4 v3 接口已冻结用于单元开发，但 A/B/C 实现尚未完成签核。

## 1. 结论与本阶段目标

当前应执行 D2，不做正式硬件消融，也不做板测签核。D2 的目标是冻结一套可独立复现的验证规则，使后续 A、B、C 提交候选后，D 能用同一套输入、参考、阈值、协议断言、计数器和产物身份规则给出 `READY` 或 `NOT READY`。

本阶段允许：

- 编写独立 Python/reference、输入生成器、日志解析器、协议检查器和测试脚本。
- 固定 full、stress、随机、定向、反压、reset 和错误注入测试矩阵。
- 固定输入、golden、报告和脚本的 SHA-256。
- 复核历史软件报告，并把已知失败保留为可重复风险证据。
- 定义后续 RTL/XSim/板测必须输出的 telemetry 和 artifact schema。

本阶段禁止：

- 修改生产 QK、Softmax、PV、DMA、CDC 或 board RTL。
- 修改 golden 数据或项目阈值。
- 根据输入文件名、seed 或测试身份切换数值模式。
- 把 Python `math.exp`、历史软件报告或 mock-IP 结果写成硬件结果。
- 因压力用例失败而删除 seed、放宽阈值或覆盖原始失败报告。
- 在没有完整 A/B/C 候选时开展正式 `row vs online`、`1/2/4 cluster` 性能消融。

## 2. 第一步：建立干净的 D2 工作基线

### 2.1 核对本地接口标签

在仓库根目录执行：

```powershell
git status --short --branch
git rev-parse 'CATS_R4_INTERFACE_V3_COMMIT^{commit}'
git --no-pager show CATS_R4_INTERFACE_V3_COMMIT:docs/CATS_R4_INTERFACE_V3.md
```

必须得到：

```text
4d386e0f8f39c9f3c6de5ffa2ced408f254146ee
```

此前 `git fetch` 连接 GitHub 失败不影响已经存在的本地标签。恢复网络后可以再次 fetch，但不得移动或重建该标签。

### 2.2 建立独立 D2 worktree

为避免覆盖 `main`、D1 文件或其他成员改动，建议从 v3 标签建立独立工作树：

```powershell
git worktree add ..\Llama3-8B-Attention-Optimize-D2 `
  -b codex/d-validation-v3 `
  CATS_R4_INTERFACE_V3_COMMIT

Set-Location ..\Llama3-8B-Attention-Optimize-D2
```

如果 `codex/d-validation-v3` 已存在，应进入现有 worktree，不要重复创建或强制覆盖。

### 2.3 记录 D2 身份

保存以下信息：

- branch、base commit、当前 HEAD。
- `CATS_R4_INTERFACE_V3_COMMIT^{commit}` 完整 SHA。
- Python 版本、操作系统、测试工具版本。
- D1 签核提交或 D1 JSON/Markdown 的 SHA-256。
- 工作树是否干净；所有已有未提交文件归属。

## 3. 第二步：验证 v3 冻结资料和历史研究原件

在 D2 worktree 运行：

```powershell
python tests/check_cats_r4_lead_release.py
python tests/test_cats_r4_v3_capacity.py
```

预期结果：

- 历史研究原件 SHA-256 校验通过。
- 8 个输入文件身份校验通过。
- full/stress JSON 结构与历史指标检查通过。
- v3 容量、bank 映射、workload invariant 和非法 cluster 参数测试通过。

必须明确：这一步只证明冻结资料、输入和规划算术没有被篡改，不证明 B2、RTL、XSim、OOC 或硬件通过。

建议输出：

- `artifacts/d2/D2_LEAD_RELEASE_CHECK.log`
- `artifacts/d2/D2_V3_CAPACITY_CHECK.log`
- `artifacts/d2/D2_INPUT_HASH_MANIFEST.json`

其中 manifest 至少记录 Q、K、V、golden、sin、cos、exp LUT、参考脚本和历史报告的相对路径、字节数与 SHA-256。

## 4. 第三步：冻结两套独立数值参考

D2 必须明确区分两种参考，不能只复制生产 RTL。

### 4.1 项目 RTL 语义参考

用途：判断实现是否遵守项目声明的舍入和运算边界。

应覆盖：

- BF16 输入解析和 RNE 输出。
- QK score 的现有 BF16 舍入边界。
- Compatibility 模式的 BF16/Q15 语义；未由 B 声明的细节标为 `OPEN`。
- Accuracy 模式完整行 max。
- Accuracy weight 为 FP32 raw bits 的 `exp(score-row_max)`，不经过 BF16/Q15。
- key 递增的 FP32 sum 和 PV 累加；乘法与加法分别 RNE，不使用未声明 FMA。
- 行末 `reciprocal + multiply` 后 BF16 RNE；不能用历史最终 division 冒充同一边界。
- causal mask：`key > row`，masked weight 存储为 `+0`，不计有效 exp/PV 工作。

现有 `python/flash_attention_tile_model.py` 可以作为项目历史语义参考之一，但不能作为唯一独立数学参考。

### 4.2 独立数学语义参考

用途：发现项目实现共同复制的数值错误。

应独立实现：

- 使用高精度或 FP64 计算完整 softmax。
- 使用稳定形式 `exp(score-max)`。
- sum 和 PV 使用 `math.fsum` 或等价的独立高精度累加。
- 仅在最终输出处转换为 BF16 RNE。
- 不读取生产 exp LUT，不复制生产 reciprocal 或状态机代码。
- 对 NaN、Inf、负 weight、`sum<=0` 和非法全 mask 行给出独立分类。

### 4.3 固定比较规则

项目现有门禁固定为：

```text
absolute_error <= 1e-4 OR BF16 ordered ULP distance <= 1
```

每个比较必须输出：

- `elements`
- `different`
- `strict_abs_failures`
- `over_one_ulp`
- `combined_failures`
- `max_abs_error`
- `max_ulp`
- 最坏元素的 head、row、feature、actual、expected、abs error、ULP

不得只输出 PASS/FAIL。

## 5. 第四步：建立并执行 D2 测试矩阵

### 5.1 full 数据

输入：仓库正式 Q/K/V、RoPE、LUT 和 golden。  
范围：32 Q heads × 128 rows × 128 features，共 524,288 个输出。  
目的：确认项目数据集的 Compatibility/Accuracy 软件候选行为和输入身份。

必须保留历史事实：四种历史软件候选在 full 数据上 `combined_failures=0`，但这不是硬件通过。

输出：

- `artifacts/d2/D2_FULL_NUMERICAL_REPORT.json`
- `artifacts/d2/D2_FULL_NUMERICAL_REPORT.md`

### 5.2 固定 stress 数据

固定 `seed=20260905`、32 cases、4,096 elements。覆盖近似相等 score、后部最大值、长尾、小概率、正负 V 抵消和 causal 边界。

必须保留历史风险：

- `online_q15 combined_failures=482`
- `row_q15 combined_failures=459`
- `row_fp32_exp_software combined_failures=0`

最后一项使用 Python `math.exp`，只能写“软件候选通过”，不能推断硬件 exp 通过。

输出：

- `artifacts/d2/D2_STRESS_SEED_20260905.json`
- `artifacts/d2/D2_STRESS_SEED_20260905.md`

### 5.3 已知失败 seed 复现

固定复现 `seed=12794`、1 case、S=D=128、tile=4。现有证据文件为 `D2_REPRO_SEED_12794.json`。

必须复现并记录：

- fused tile vs scalar tile：`combined_failures=0`
- fused vs mathematical reference：`combined_failures=10`
- fused vs v3.0：`combined_failures=13`
- v3.0 vs mathematical reference：`combined_failures=23`

参考执行方式：

```powershell
python python/flash_attention_tile_model.py `
  --synthetic `
  --seed 12794 `
  --cases 1 `
  --length 128 `
  --dimension 128 `
  --tile 4 `
  --json artifacts/d2/D2_REPRO_SEED_12794_RERUN.json
```

该历史脚本可能因 `fused_vs_mathematical_reference` 不满足门禁而返回非零退出码。这是已知数值风险的成功复现，不得改阈值使它返回 PASS。D2 runner 应把它作为“expected diagnostic failure”单独断言：退出码和 JSON 指标都必须符合预期。

### 5.4 随机合法输入

至少固定一组不可变 seed 列表，建议 32 个 seed。每个 seed 保存：

- Q/K/V 生成参数和哈希。
- numeric mode。
- score、weight、sum、inv_sum 和 Context 指标。
- 第一个失败位置及最小复现数据。

随机生成不得根据结果重抽 seed。

### 5.5 定向数值用例

至少包含：

1. 所有有效 scores 相等。
2. 最大 score 位于第一个 key。
3. 最大 score 位于最后一个合法 key。
4. 后部最大值大幅突增。
5. `score-max` 位于 exp 近似分段/下溢边界附近。
6. 长尾小 weight。
7. V 全零、全正、全负、正负抵消。
8. causal `row=0` 与 `row=127`。
9. 尾部短 slab。
10. BF16 最大有限值、最小 normal/subnormal、正负零。
11. 非有限 score、负/非有限 weight、`sum<=0`、非有限 inv_sum。
12. 非法 numeric mode 2/3。

非法数值用例的预期是拒绝/计错，不是正常输出 Context。

### 5.6 协议与反压用例

D2 先冻结检查规则；A/B/C RTL 到达后按相同规则执行：

- `valid=1 && ready=0` 时全部 payload、token、last、mask 保持稳定。
- 随机 request/response latency 和 output backpressure。
- reset、soft reset、epoch 切换、旧 completion 丢弃。
- duplicate/missing commit、last 错位、mask 错位、错误 owner、提前 slot reuse。
- weight response 固定为请求接受后的 N+2 周期，且 response 无 ready。
- release 前必须满足 outstanding=0 且最后输出已接受。
- 正向用例 error counter 全零；负向用例只允许指定 counter 精确增加。

## 6. 第五步：冻结 telemetry 和 counter 闭合

### 6.1 每条事件必须记录

- event 名称、clock domain、cycle/timestamp。
- `epoch`、`group`、`global_q_head`、`row`、`slot_id`、`numeric_mode`。
- 适用时记录 key、feature、mask、last、seq、valid、ready。
- request、response、issue、result、commit、release 的唯一序号。
- seed、输入 hash、候选 commit、接口 tag。

### 6.2 full 正常事务的固定工作量

| 项目 | 期望值 |
|---|---:|
| 有效 exp | 264,192 |
| 有效 QK MAC | 33,816,576 |
| 有效 PV MAC | 33,816,576 |
| Context words | 524,288 |
| weight 写入（含 masked 的零存储） | 524,288 |
| row commit | 4,096 |
| PV row 发布 | 4,096 |
| weight release | 4,096 |
| DDR read beats | 196,608 |
| DDR write beats | 131,072 |
| rows committed | 4,096 |

注意：有效计算量与存储流量必须分开。masked 项可写零，但不能算作有效 exp/PV 工作。`weight_rd_request` 必须与实际协议声明一致，并始终满足 request=response；不能把 32-feature 广播重复计成新 exp。

### 6.3 必须闭合的 v3 weight counter

- `weight_wr_accept`
- `weight_rd_request`
- `weight_rd_response`
- `row_commit_count`
- `pv_row_count`
- `weight_release_count`
- `owner_error`
- `mask_error`
- `last_error`
- `mode_error`
- `numeric_error`
- `epoch_drop`
- `bank_conflict`
- `outstanding_max`

### 6.4 必须纳入系统 telemetry 的计数

- 周期：active、QK busy、Softmax busy、PV busy、output busy、no-work。
- stall：RAW、bank、FIFO、DMA、AXI、output、reorder。
- FIFO：push、pop、max occupancy、full stall、empty stall、underflow、overflow。
- output：rows enqueued/committed、seq error、tag mismatch、epoch drop。
- 每 cluster：groups、Q heads、rows、有效工作量、cycles 和 stall。

正常用例要求全部 protocol/error/conflict/underflow/overflow/seq counter 为 0。stall counter 不要求为 0，但必须能解释总周期。

### 6.5 固定三种计时边界

- core：cluster 接受命令到 group done。
- PL transaction：PL 接受 transaction 到全部 Context 写回并 snapshot。
- application：软件开始准备/启动到软件确认结果完成。

不同 clock domain 的 cycles 不得直接相加；每项同时记录时钟频率和换算后的时间。3～6 ms、6～12 ms、12～25 ms 仍是目标，不是 D2 实测结果。

## 7. 第六步：实现统一 D2 runner

建议新增以下文件：

```text
python/cats_r4_d2_reference.py
python/cats_r4_d2_protocol_checker.py
python/cats_r4_d2_report.py
tests/test_cats_r4_d2_reference.py
tests/test_cats_r4_d2_protocol_checker.py
tests/test_cats_r4_d2_contract.py
tests/run_cats_r4_d2_validation.ps1
docs/D2_VALIDATION_TELEMETRY_CONTRACT_2026-09-08.md
docs/D2_DELIVERY_2026-09-08.md
artifacts/d2/
```

统一 runner 的顺序：

1. 校验接口 tag、base/head 和工作树状态。
2. 校验输入、golden、模型和历史报告 hash。
3. 运行参考模型单测。
4. 运行 full 软件数据。
5. 运行 stress seed 20260905。
6. 运行已知失败 seed 12794 的预期失败复现。
7. 运行固定随机 seed 集合和定向用例。
8. 运行协议 checker 单测及错误注入。
9. 检查 JSON schema、计数公式和失败 seed 可重复性。
10. 执行 `git diff --check`，生成 Markdown/JSON 汇总。

runner 最终必须分别输出：

- `contract_checks_passed`
- `reference_unit_tests_passed`
- `historical_reports_verified`
- `full_software_result`
- `stress_software_result`
- `known_risks_reproduced`
- `protocol_checker_tests_passed`
- `hardware_tests_run`（D2 当前通常为 false）
- `d2_ready`

不得用一个总 PASS 掩盖“硬件尚未运行”。

## 8. D2 最终需要整理和交付的文件

### 8.1 必交源码与测试

1. 独立数学参考模型。
2. 项目语义参考或适配层。
3. BF16 RNE、ordered ULP、mask、sum/PV 顺序的单元测试。
4. 协议事件 checker 和错误注入测试。
5. 一键 D2 runner。

### 8.2 必交契约与清单

1. `D2_VALIDATION_TELEMETRY_CONTRACT_2026-09-08.md`
2. 输入/golden/model SHA-256 manifest。
3. 固定 seed manifest。
4. counter schema。
5. artifact/report JSON schema。
6. 测试矩阵和每项预期结果。

### 8.3 必交结果

1. full 软件报告 JSON/Markdown。
2. stress seed 20260905 报告 JSON/Markdown。
3. seed 12794 复现 JSON/Markdown。
4. 固定随机/定向用例汇总。
5. checker 单测日志。
6. lead release 与 v3 capacity 检查日志。
7. 所有失败 seed 和最小复现，不得删除。

### 8.4 必交 DELIVERY

`docs/D2_DELIVERY_2026-09-08.md` 必须包含：

- 阶段：D2。
- 状态：READY、NOT READY 或 BLOCKED。
- branch、base、head、接口 tag 完整 SHA。
- 修改文件列表及文件所有权说明。
- 输入、golden、模型、历史报告 hash。
- 测试命令、退出码和日志相对路径。
- full/stress/random/定向结果。
- 已知失败 seed 与最坏元素。
- 数值模式和实际运算边界。
- counter、telemetry 和 artifact schema 版本。
- 哪些是软件结果，哪些是 RTL/XSim/OOC/板测结果；未运行项明确写 `NOT RUN`。
- 已知限制、下一依赖和需要 A/B/C/队长提供的内容。

## 9. D2 的 READY 标准

D2 可以在 B2 硬件实现尚未到达时独立完成。D2 `READY` 的含义是“验证契约和工具可用于审查”，不代表 CATS-R4 实现 READY。

只有同时满足以下条件，D2 才能标 `READY`：

- v3 tag 和完整 commit 身份已记录。
- 输入、golden、参考、历史报告 hash 完整并通过检查。
- 两套参考语义边界明确，独立参考不复制生产 RTL。
- 比较阈值固定且有防放宽测试。
- full/stress/random/定向矩阵完整。
- seed 12794 及历史 stress 风险可重复，失败记录未删除。
- token、握手、epoch、last、mask、slot ownership 断言完整。
- workload、weight、DDR、Context 和 error counter schema 完整。
- core/PL/application 三种计时边界明确。
- runner、单元测试和 `git diff --check` 通过。
- 报告明确区分软件、模型、RTL、综合、实现和板测证据等级。

以下情况标 `NOT READY`：参考模型自身单测失败、hash 不一致、阈值可被参数静默放宽、失败 seed 不可复现、schema 缺字段或正常 workload 公式不闭合。

缺 B2/RTL/板卡不阻止 D2 契约 READY；应把相应测试标为 `NOT RUN`，并在下一阶段 D3 等待候选 commit。

## 10. D2 完成后的下一步

D2 READY 后停止扩大本阶段范围，将 commit SHA 和 DELIVERY 交队长。随后：

1. 等 B 提交 B2 完整源码、TB、日志、branch 和完整 SHA。
2. D 按 D2 契约复核 B2 full/stress/特殊值和反压。
3. B2、B3、A compute cluster 与 C single-board 依次到达后进入 D3。
4. D3 才做单 cluster `row vs online` 公平消融。
5. D4 才做 1/2/4 cluster 板测与扩展收益签核。

## 11. 最终交付目录示例

```text
docs/
  D2_VALIDATION_TELEMETRY_CONTRACT_2026-09-08.md
  D2_DELIVERY_2026-09-08.md
python/
  cats_r4_d2_reference.py
  cats_r4_d2_protocol_checker.py
  cats_r4_d2_report.py
tests/
  test_cats_r4_d2_reference.py
  test_cats_r4_d2_protocol_checker.py
  test_cats_r4_d2_contract.py
  run_cats_r4_d2_validation.ps1
artifacts/d2/
  D2_INPUT_HASH_MANIFEST.json
  D2_SEED_MANIFEST.json
  D2_FULL_NUMERICAL_REPORT.json
  D2_FULL_NUMERICAL_REPORT.md
  D2_STRESS_SEED_20260905.json
  D2_STRESS_SEED_20260905.md
  D2_REPRO_SEED_12794_RERUN.json
  D2_REPRO_SEED_12794_RERUN.md
  D2_VALIDATION_SUMMARY.json
  logs/
```

阶段提交建议命名：

```text
D-validation-contract: freeze independent reference telemetry and reproducible gates
```

该提交只能包含 D 拥有的验证、报告和契约文件，不应混入生产 RTL、golden 修改、生成目录或其他成员文件。
