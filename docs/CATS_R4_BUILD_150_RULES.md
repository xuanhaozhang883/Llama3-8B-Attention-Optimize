# CATS-R4 150 MHz 干净构建与证据规则

状态：流程准备；本文件不启动 full-board，也不授予生产 top/manifest 修改许可。
接口：CATS_R4_INTERFACE_V3_COMMIT。先读 CATS_R4_LEAD_ACCEPTANCE_ADDENDUM.md。

## 环境身份

目标 Vivado/Vitis 2025.2、xczu15eg-ffvb1156-2-i，axi/core 首版 150 MHz。
实际工具版本必须以本机 version 输出记录，不把目标值冒充检测结果。
build root 建议 D:/Vitis/FPT/b/c2_150_<shortsha>_<runid>，必须是全新、短 ASCII 路径，
位于 clone 外；同名目录已存在则停止或换新 runid，禁止清空/复用旧工程。
目前只规划路径；创建仓库外目录时需相应写入授权。

## 执行次序与停止条件

1. 只读 preflight：核对源 SHA、消费 tag、A/B/wrapper READY 证据及未提交差异。
2. 先 contract-only elaboration/TB、真实 XPM 连续读、CDC/reset、burst/output 回归。
3. 单元 OOC：真实 IP 配置、资源和约束；blackbox 结果不得替代真实 IP。
4. 队长接受生产 manifest/top/BD/constraints 差异后进入 full-board synthesis、implementation。
5. 检查 routed setup/hold、所有时钟/未约束路径和 DRC；失败停止，不生成交付 XSA。
6. 通过整板门禁后生成 BIT/含 bit XSA；用该 XSA 新建 Vitis workspace/BSP/app，再生成 ELF。
7. 板测绑定同一组源、XSA、ELF 和输入哈希；不复用 v3.1.4 XSA/BSP/板测结果。

200 MHz、2/4 cluster 使用独立源提交与 build root，各自验收，不借用单 cluster 150 MHz 结论。
现有 tests/run_cats_r4_c2_preflight.ps1 是历史入口；运行前需审查是否仍硬编码旧 tag/16-bit weight。
本规则不声称该脚本已升级为 v3 自动构建器。

## 每次构建必须归档的 manifest

source manifest：repo URL、完整 head/base SHA、接口 tag 解引用 SHA、dirty diff、
按实际编译顺序的相对源路径和 SHA256、include/define、IP 参数/版本、约束哈希。

tool manifest：Vivado/Vitis 实测版本、可执行路径、器件、clock、OS、UTC 起止时间、
全新 build root 绝对路径、每阶段命令和退出码。

test manifest：test id、输入/参考/日志 SHA256、seed、数值模式、预期/实际 counter、
PASS/FAIL/NOT RUN、错误样本、审阅人和审阅源 SHA。

artifact manifest：DCP、Timing、DRC、BIT/XSA/ELF 的路径/哈希及生成命令；
未到产物阶段写 NOT GENERATED，禁止借用历史产物填表。

## 队长关闭条件

所有门禁证据均绑定此次源身份；正常负载 rd_beats=196608、wr_beats=131072、
rows_committed=4096，错误计数为零。负向测试另表记录预期错误增量。
WNS 非负不等于所有门禁通过：还需 hold、约束覆盖、DRC、功能和产物身份链。
