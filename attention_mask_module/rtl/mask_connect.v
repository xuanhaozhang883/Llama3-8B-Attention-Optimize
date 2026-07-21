causal_mask_stream #(
    .SCORE_WIDTH(16),
    .POS_WIDTH(7),
    .HEAD_WIDTH(5)
) u_causal_mask (
    .clk          (clk),
    .rst_n        (rst_n),

    .causal_en    (1'b1),
    .mask_value   (16'hFF80),

    // QK 输出
    .s_valid      (qk_out_valid),
    .s_ready      (qk_out_ready),
    .s_score      (qk_out_score),
    .s_head_idx   (qk_out_head),
    .s_q_pos      (qk_out_q_pos),
    .s_k_pos      (qk_out_k_pos),
    .s_row_last   (qk_out_row_last),

    // 连接 Softmax
    .m_valid      (mask_out_valid),
    .m_ready      (softmax_in_ready),
    .m_score      (mask_out_score),
    .m_head_idx   (mask_out_head),
    .m_q_pos      (mask_out_q_pos),
    .m_k_pos      (mask_out_k_pos),
    .m_row_last   (mask_out_row_last)
);