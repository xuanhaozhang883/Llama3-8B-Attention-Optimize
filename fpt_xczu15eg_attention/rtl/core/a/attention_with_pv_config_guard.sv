`timescale 1ns/1ps

// v2.6 configuration guard.  The optimized default is 2/4/2 for
// QK_LANES/CAPTURE_TILE/PV_LANES; 1/2/1 is the exact v2.5 fallback.
module attention_with_pv_config_guard #(
    parameter int QK_TILE       = 4,
    parameter int QK_LANES      = 2,
    parameter int CAPTURE_TILE  = 4,
    parameter int BC_PV_TILE    = CAPTURE_TILE,
    parameter int REAL_PV_TILE  = 4,
    parameter int PV_LANES      = 2,
    parameter int SEQ_LEN       = 128,
    parameter int HEAD_DIM      = 128,
    parameter int Q_HEADS       = 4,
    parameter int GQA_GROUPS    = 8
) ();

    initial begin
        if (QK_TILE != 4)
            $error("A+PV: verified QK delivery requires QK_TILE=4");

        if ((QK_LANES != 1) && (QK_LANES != 2))
            $error("A+PV: QK_LANES must be 1 or 2");

        if ((CAPTURE_TILE != 2) && (CAPTURE_TILE != 4))
            $error("A+PV: CAPTURE_TILE must be 2 or 4");

        if (BC_PV_TILE != CAPTURE_TILE)
            $error("A+PV: BC_PV_TILE must equal CAPTURE_TILE");

        if (REAL_PV_TILE != 4)
            $error("A+PV: uploaded pv_systolic_gqa_top is integrated as TILE=4");

        if ((PV_LANES != 1) && (PV_LANES != 2))
            $error("A+PV: PV_LANES must be 1 or 2");

        if ((CAPTURE_TILE == 2) && (PV_LANES != 1))
            $error("A+PV: v2.5 TILE2 fallback requires PV_LANES=1");

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

        if ((HEAD_DIM % (REAL_PV_TILE*PV_LANES)) != 0)
            $error("A+PV: REAL_PV_TILE*PV_LANES must divide HEAD_DIM");
    end

endmodule
