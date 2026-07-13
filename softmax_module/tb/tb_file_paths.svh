// Run xsim from the repository root so these paths remain portable.
`define INPUT_HEX_FILE        "softmax_module/data/input_scores_bf16.mem"
`define MASK_HEX_FILE         "softmax_module/data/input_masks.mem"
`define EXPECTED_BF16_FILE    "softmax_module/data/expected_probs_bf16.mem"
`define EXPECTED_FP32_FILE    "softmax_module/data/expected_probs_fp32.mem"
`define RESULT_CSV_FILE       "softmax_module/results/softmax_results.csv"
`define ROW_SUMMARY_CSV_FILE  "softmax_module/results/softmax_row_summary.csv"
`define EXP_LUT_FILE          "softmax_module/rtl/exp_lut_q15.mem"
`define SOFTMAX_TOL_ABS       0.0025
