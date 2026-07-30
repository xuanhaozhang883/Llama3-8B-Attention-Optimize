`timescale 1ns/1ps

// Exact contract used by the corrected A+B+C+PV integration:
//   B+C v5 PV stream: TILE=2 (formal delivery restriction)
//   Uploaded real PV core: TILE=4
module attention_with_pv_config_guard #(
    parameter int QK_TILE       = 4,
    parameter int BC_PV_TILE    = 2,
    parameter int REAL_PV_TILE  = 4,
    parameter int SEQ_LEN       = 128,
    parameter int HEAD_DIM      = 128,
    parameter int Q_HEADS       = 4,
    parameter int GQA_GROUPS    = 8
) ();

    initial begin
        if (QK_TILE != 4)
            $error("A+PV: verified QK delivery requires QK_TILE=4");

        if (BC_PV_TILE != 2)
            $error("A+PV: B+C v5 qk_softmax_pv_pipeline_top requires PV_TILE=2");

        if (REAL_PV_TILE != 4)
            $error("A+PV: uploaded pv_systolic_gqa_top is integrated as TILE=4");

        if (Q_HEADS != 4)
            $error("A+PV: one Llama GQA Group contains 4 local Q heads");

        if (GQA_GROUPS != 8)
            $error("A+PV: Llama3.1-8B requires 8 GQA Groups");

        if ((SEQ_LEN < 1) || (HEAD_DIM < 1))
            $error("A+PV: dimensions must be positive");

        if ((SEQ_LEN % QK_TILE) != 0)
            $error("A+PV: QK_TILE must divide SEQ_LEN");

        if ((SEQ_LEN % BC_PV_TILE) != 0 ||
            (HEAD_DIM % BC_PV_TILE) != 0)
            $error("A+PV: BC_PV_TILE must divide SEQ_LEN and HEAD_DIM");

        if ((SEQ_LEN % REAL_PV_TILE) != 0 ||
            (HEAD_DIM % REAL_PV_TILE) != 0)
            $error("A+PV: REAL_PV_TILE must divide SEQ_LEN and HEAD_DIM");
    end

endmodule
