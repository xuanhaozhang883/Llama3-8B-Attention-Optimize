# QK脉动阵列下一阶段验证包

你已经完成：
- TILE=2/4 的局部tile验证
- 4个Q head、SEQ_LEN=4、HEAD_DIM=128 的64个输出全部bit-exact PASS

本包用于继续完成：
1. SEQ_LEN=8：256个结果
2. SEQ_LEN=16：1024个结果
3. SEQ_LEN=32：4096个结果
4. SEQ_LEN=128：65536个结果，写出rtl_scores_seq128.hex
5. Python全量比较
6. TILE=2与TILE=4综合资源/时序对比

文件：
- tb/tb_qk_systolic_gqa_4heads_seq8.sv
- tb/tb_qk_systolic_gqa_4heads_seq16.sv
- tb/tb_qk_systolic_gqa_4heads_seq32.sv
- tb/tb_qk_systolic_gqa_4heads_seq128_dump.sv
- python/compare_rtl_scores.py
- rtl/qk_systolic_gqa_tile2_cfg.sv
- rtl/qk_systolic_gqa_tile4_cfg.sv
- constraints/qk_100mhz.xdc

注意：
- testbench默认数据路径为 D:/qk_sim_data/
- 全量结果写到 D:/qk_sim_data/rtl_scores_seq128.hex
- 如果你的文件在别处，修改testbench中的$readmemh和$fopen路径
- 仿真文件必须作为Simulation Sources加入
- 两个cfg wrapper必须作为Design Sources加入
