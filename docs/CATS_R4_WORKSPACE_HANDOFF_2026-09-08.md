# CATS-R4 工作区交接文件

生成日期：2026-09-08  
用途：切换到新工作区后，恢复当前队长兼 C 负责人工作状态。  
项目：`https://github.com/xuanhaozhang883/Llama3-8B-Attention-Optimize.git`

## 1. 当前 Git 身份

- 当前分支：`codex/cats-r4-local-integration`
- 当前 HEAD：`132be51`（`lead: record C protocol-only evidence boundary`）
- 远端：`origin` 指向上述 GitHub 仓库
- 接口冻结 tag：`CATS_R4_INTERFACE_V3_COMMIT`
- v3 tag 用途：解除 Accuracy FP32 weight 的单元开发阻塞；不代表系统 READY
- 工作树中已有未跟踪目录：`artifacts/raw_logs/`

### 新工作区恢复命令

```powershell
git clone https://github.com/xuanhaozhang883/Llama3-8B-Attention-Optimize.git
cd Llama3-8B-Attention-Optimize
git fetch origin codex/cats-r4-local-integration
git checkout -B codex/cats-r4-local-integration origin/codex/cats-r4-local-integration
git fetch origin tag CATS_R4_INTERFACE_V3_COMMIT
git rev-parse HEAD
git rev-parse CATS_R4_INTERFACE_V3_COMMIT^{commit}
```

预期 HEAD 为 `132be51`；若远端已出现更晚的队长提交，以远端分支实际 HEAD 为准，并记录新 SHA。

## 2. 已完成的队长输出

- `docs/CATS_R4_INTERFACE_V3.md`：Accuracy FP32 weight、token、ownership、握手、容量和计数冻结。
- `docs/CATS_R4_TEAM_RULES_2026-09-08.md`：当前协作规则；允许提交 NOT READY checkpoint。
- `docs/CATS_R4_CURRENT_TEAM_BASELINE.md`：团队当前入口和未解除问题。
- `docs/CATS_R4_RELEASE_GATE.md`：人工发布门禁。
- `docs/CATS_R4_RELEASE_GATE.json`：机器可读门禁状态。
- `docs/CATS_R4_DELIVERY_TEMPLATE.md`：成员交付模板。
- `docs/CATS_R4_C_INTERFACE_MATRIX_2026-09-08.md`：bridge 条款矩阵。
- `docs/CATS_R4_C_BRIDGE_AUDIT_2026-09-08.md`：C bridge 源码审计。
- `docs/CATS_R4_C_PROTOCOL_EVIDENCE_2026-09-08.md`：protocol-only 实测边界。
- `docs/CATS_R4_LEAD_ACCEPTANCE_ADDENDUM.md`：职责和审计范围纠正。
- `docs/CATS_R4_BUILD_150_RULES.md`：150 MHz 干净构建和 manifest 规则。
- `docs/CATS_R4_LEAD_STATUS_2026-09-08.md`：队长状态摘要。

## 3. 已恢复的历史报告

目录：`docs/architecture_study_20260905/`

- `row_candidates_full.json`
- `row_candidates_stress.json`
- 两个历史生成脚本和 README

校验命令：

```powershell
python tests/check_cats_r4_lead_release.py
python tests/test_cats_r4_v3_capacity.py
python tests/check_cats_r4_gate_manifest.py
```

预期：全部 PASS。报告是软件研究原件，不是 RTL、Vivado、OOC 或板级验收证据。

## 4. 当前已实测证据

Protocol-only bridge 使用 Icarus 运行过：

```powershell
iverilog -g2012 -DCATS_R4_PROTOCOL_ONLY -s tb_cats_r4_qkv_axi_bank_bridge `
  -o artifacts/raw_logs/bridge_protocol_vvp/bridge.vvp `
  rtl/core/cluster/cats_r4_qkv_axi_bank_bridge.sv `
  tb/tb_cats_r4_qkv_axi_bank_bridge.sv
vvp artifacts/raw_logs/bridge_protocol_vvp/bridge.vvp
```

结果包含 Q/K/V descriptor、counter、premature `wr_last`、reset reopen、token mismatch，
并输出 `PASS: CATS-R4 AXI/core bank bridge descriptors and counters`。

重要边界：该宏排除了 XPM RAM 和 core readback，不能证明真实 XPM N+2、bank readback、CDC、
4 KiB burst split、AXI 短尾、v3 weight slab 或 C2 counter closure。

## 5. 当前门禁状态

| 项目 | 状态 |
|---|---|
| 历史资料归档 | READY |
| v3 接口 | READY FOR UNIT DEVELOPMENT |
| A 单元 | NOT READY |
| B 单元 | NOT READY；等待可审查 B2 源码 SHA |
| C bridge | NOT READY |
| C 上层 DMA/CDC/output | NOT READY |
| C2 整板 | BLOCKED AT ENTRY GATE |

禁止据此生成 BIT/XSA/ELF，禁止修改 production manifest、board top、BD、constraints 以绕过门禁。

## 6. 下一工作区第一轮动作

1. 运行第 3 节的三个 Python 校验。
2. 读取 `docs/CATS_R4_RELEASE_GATE.json`，确认整体仍是 `NOT_READY`。
3. 获取 B2 队友 branch、完整 head SHA、RTL/TB/脚本/日志；截图不能替代源码。
4. 用 `CATS_R4_DELIVERY_TEMPLATE.md` 记录交付身份和输入/日志哈希。
5. 对照 `CATS_R4_C_INTERFACE_MATRIX_2026-09-08.md` 完成 IF_V1/IF_V2/v3 差异审计。
6. 有 Vivado 2025.2 后，先跑 contract-only/XPM/OOC，再考虑 150 MHz C2。

## 7. 不要做的事

- 不要把历史 JSON 的 `combined_failures=0` 宣称成硬件通过。
- 不要把 protocol-only PASS 宣称成真实 XPM 或 C2 READY。
- 不要把 B 的 Accuracy FP32 weight 责任写成 A 的生产实现。
- 不要复用 v3.1.4 的 XSA/BSP/ELF 作为 CATS-R4 证据。
- 不要 force-push 共享分支或移动已发布 tag。
- 不要删除或覆盖旧工作区的 `artifacts/raw_logs/`；需要分享时单独归档并计算哈希。
