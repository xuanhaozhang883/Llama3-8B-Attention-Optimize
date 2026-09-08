# 历史数值研究原件

2026-09-08 从仓库外 `D:/Vitis/FPT/docs/architecture_study_20260905/` 找回，按原始字节归档。
两份 JSON 是研究结果，不是输入向量、硬件测试日志或 B2 新实现的验收报告。

- `row_candidates_full.json`：32 heads × 128 rows，524288 outputs；四种软件候选 combined_failures 均为 0。
- `row_candidates_stress.json`：seed=20260905，32 cases；online_q15/row_q15 分别失败 482/459，FP32 software exp 为 0。
- 两份 `*_study.py` 保留历史生成程序；其中 ROOT 是旧目录布局，不能直接在新位置运行。复现时在个人分支显式改 ROOT，并把新结果输出到不同目录，保留原件。

验收阈值是项目定义的 abs<=1e-4 OR BF16 ordered distance<=1，不声称为官方比赛规则。
Python math.exp 不等于硬件 exp；历史 division 不等于 v3 reciprocal+multiply，B 必须独立回归。
JSON 中绝对路径仅为历史出处；校验脚本按仓库相对路径查找输入，不执行这些路径。

在仓库根目录运行 `python tests/check_cats_r4_lead_release.py`。
校验包含原件 SHA256、报告结构和当前输入字节身份；它不是重跑数值算法。
原件哈希固定在该脚本中；本目录 .gitattributes 禁止自动换行转换。
