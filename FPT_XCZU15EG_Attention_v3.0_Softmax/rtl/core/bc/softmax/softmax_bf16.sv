`timescale 1ns/1ps

// Interface-compatible streaming Softmax for a BF16 score row.
//
// The input pass accepts one score/cycle and records the final row maximum.
// A pipelined correction pass then accumulates exp(max-score) in column order,
// matching the archived implementation's Q1.15 denominator bit for bit. The
// six-stage elastic output pipeline emits one probability/cycle.
module softmax_bf16 #(
    parameter int MAX_LEN    = 128,
    parameter int SCORE_W    = 24,
    parameter int SCORE_FRAC = 14,
    parameter int HEAD_W     = 2,
    parameter int POS_W      = 7,
    parameter bit REQUIRE_FULL_ROW = 1'b1,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        in_valid,
    output logic        in_ready,
    input  logic [15:0] in_data,
    input  logic        in_last,
    input  logic        in_mask,
    input  logic [HEAD_W-1:0] in_head,
    input  logic [POS_W-1:0]  in_row,
    input  logic [POS_W-1:0]  in_col,

    output logic        out_valid,
    input  logic        out_ready,
    output logic [15:0] out_data,
    output logic        out_first,
    output logic        out_last,
    output logic [HEAD_W-1:0] out_head,
    output logic [POS_W-1:0]  out_row,
    output logic [POS_W-1:0]  out_col,

    output logic        busy,
    output logic        row_error,
    output logic        metadata_error
);

    localparam int ADDR_W = (MAX_LEN <= 2) ? 1 : $clog2(MAX_LEN);
    localparam int LEN_W  = (MAX_LEN <= 1) ? 1 : $clog2(MAX_LEN + 1);
    localparam int SUM_W  = 16 + $clog2(MAX_LEN + 1);
    localparam int RECIP_NUM_W = 46;
    localparam int EXP_ADDR_SHIFT = SCORE_FRAC - 6;
    localparam logic signed [SCORE_W:0] EXP_LIMIT_FIXED = 8 <<< SCORE_FRAC;
    localparam logic signed [SCORE_W:0] EXP_ROUND_BIAS =
        1 <<< (EXP_ADDR_SHIFT-1);
    localparam logic [7:0] BF16_SHIFT_BIAS = 134 - SCORE_FRAC;
    localparam logic [7:0] BF16_SAT_EXP    = (134 - SCORE_FRAC) + SCORE_W - 8;
    localparam logic [7:0] BF16_ZERO_EXP   = (134 - SCORE_FRAC) - 9;

    initial begin
        if (MAX_LEN < 1)
            $error("MAX_LEN must be >= 1");
        if (SCORE_FRAC < 7)
            $error("SCORE_FRAC must be >= 7");
        if (SCORE_W < 8)
            $error("SCORE_W must be >= 8");
        if (((134 - SCORE_FRAC) < 9) ||
            (((134 - SCORE_FRAC) + SCORE_W - 8) > 254))
            $error("SCORE_W/SCORE_FRAC are outside the optimized BF16 converter range");
        if ((1 << POS_W) < MAX_LEN)
            $error("POS_W is too small for MAX_LEN");
    end

    typedef enum logic [3:0] {
        ST_LOAD,
        ST_DENOM,
        ST_RECIP_START,
        ST_RECIP_WAIT,
        ST_OUTPUT
    } state_t;
    state_t state;

    // Scores and masks are retained for exact denominator and output scans.
    (* ram_style = "distributed" *) logic signed [SCORE_W-1:0] score_mem [0:MAX_LEN-1];
    (* ram_style = "distributed" *) logic                      mask_mem  [0:MAX_LEN-1];

    logic [LEN_W-1:0] wr_count;
    logic [LEN_W-1:0] row_len;
    logic signed [SCORE_W-1:0] max_score;
    logic have_unmasked;
    logic all_masked_row;
    logic [SUM_W-1:0] sum_exp;
    logic [30:0] recip_q30;
    logic [HEAD_W-1:0] row_head_reg;
    logic [POS_W-1:0] row_index_reg;

    // Two input stages retain the existing one-beat-per-cycle BF16 conversion
    // contract and keep conversion out of the maximum comparison's timing cone.
    logic                      raw_stage_valid;
    logic [15:0]               raw_stage_data;
    logic                      raw_stage_last;
    logic                      raw_stage_mask;
    logic [HEAD_W-1:0]         raw_stage_head;
    logic [POS_W-1:0]          raw_stage_row;
    logic [POS_W-1:0]          raw_stage_col;
    logic                      load_stage_valid;
    logic signed [SCORE_W-1:0] load_stage_fixed;
    logic                      load_stage_last;
    logic                      load_stage_mask;
    logic [HEAD_W-1:0]         load_stage_head;
    logic [POS_W-1:0]          load_stage_row;
    logic [POS_W-1:0]          load_stage_col;

    // Exact-denominator pipeline: memory read -> EXP address -> LUT capture ->
    // ordered accumulation. After fill it accepts one stored score/cycle.
    logic [2:0] denom_pipe_valid;
    logic [ADDR_W-1:0] denom_issue_idx;
    logic denom_issue_done;
    logic signed [SCORE_W-1:0] denom_score_reg;
    logic denom_mask_reg;
    logic signed [SCORE_W:0] denom_exp_magnitude;
    logic signed [SCORE_W:0] denom_exp_rounded;
    logic [9:0] denom_exp_addr;
    logic denom_exp_forced_zero;
    logic [9:0] denom_exp_addr_reg;
    logic denom_exp_forced_reg;
    logic [15:0] denom_exp_value_reg;

    // Six-stage, globally-stalled output pipeline.
    logic [5:0] pipe_valid;
    logic [POS_W-1:0] pipe_col [0:5];
    logic pipe_first [0:5];
    logic pipe_last [0:5];
    logic signed [SCORE_W-1:0] pipe_score_reg;
    logic pipe_mask_reg;
    logic [9:0] pipe_exp_addr_reg;
    logic pipe_exp_forced_reg;
    logic [15:0] pipe_exp_value_reg;
    logic [46:0] pipe_product_reg;
    logic [15:0] pipe_q15_reg;
    logic [15:0] pipe_bf16_reg;
    logic [POS_W-1:0] issue_idx;
    logic issue_done;
    logic pipe_advance;

    logic signed [SCORE_W:0] output_exp_magnitude;
    logic signed [SCORE_W:0] output_exp_rounded;
    logic [9:0] output_exp_addr;
    logic output_exp_forced_zero;
    logic [9:0] exp_lut_addr;
    logic [15:0] exp_lut_data;

    logic [46:0] output_probability_rounded;
    logic [16:0] output_probability_q15_ext;
    logic [15:0] output_probability_q15;

    // Probability multiply used by the elastic output pipeline.
    logic [46:0] shared_product;

    logic div_start;
    logic div_busy;
    logic div_done;
    logic div_by_zero;
    logic [RECIP_NUM_W-1:0] div_quotient;
    logic [SUM_W-1:0] div_remainder;

    integer pipe_index;

    function automatic logic signed [SCORE_W-1:0] bf16_to_fixed(
        input logic [15:0] value_bf16
    );
        logic sign_bit;
        logic [7:0] exponent;
        logic [6:0] fraction;
        logic [7:0] significand;
        logic [SCORE_W-1:0] magnitude;
        logic [8:0] rounded_significand;
        logic [4:0] left_shift;
        logic [3:0] right_shift;
        begin
            sign_bit   = value_bf16[15];
            exponent   = value_bf16[14:7];
            fraction   = value_bf16[6:0];
            significand = {1'b1, fraction};
            magnitude  = '0;
            rounded_significand = '0;
            left_shift  = '0;
            right_shift = '0;

            if (exponent == 8'h00) begin
                bf16_to_fixed = '0;
            end else if (exponent == 8'hff) begin
                if (fraction != 7'd0)
                    bf16_to_fixed = '0;
                else
                    bf16_to_fixed = sign_bit ?
                        {1'b1, {(SCORE_W-1){1'b0}}} :
                        {1'b0, {(SCORE_W-1){1'b1}}};
            end else if (exponent >= BF16_SAT_EXP) begin
                bf16_to_fixed = sign_bit ?
                    {1'b1, {(SCORE_W-1){1'b0}}} :
                    {1'b0, {(SCORE_W-1){1'b1}}};
            end else if (exponent <= BF16_ZERO_EXP) begin
                bf16_to_fixed = '0;
            end else begin
                if (exponent >= BF16_SHIFT_BIAS) begin
                    left_shift = exponent - BF16_SHIFT_BIAS;
                    magnitude = {{(SCORE_W-8){1'b0}}, significand} << left_shift;
                end else begin
                    right_shift = BF16_SHIFT_BIAS - exponent;
                    rounded_significand = {1'b0, significand} +
                                          (9'd1 << (right_shift-1'b1));
                    magnitude = rounded_significand >> right_shift;
                end
                if (sign_bit)
                    bf16_to_fixed = -$signed(magnitude);
                else
                    bf16_to_fixed = $signed(magnitude);
            end
        end
    endfunction

    function automatic logic [15:0] q15_to_bf16(
        input logic [15:0] q15_value
    );
        integer msb_index;
        integer shift_left;
        integer k;
        logic [31:0] normalized;
        logic [6:0] fraction7;
        logic round_bit;
        logic sticky_bit;
        logic [7:0] rounded_fraction;
        logic [7:0] exponent_biased;
        integer exponent_temp;
        begin
            if (q15_value == 16'd0) begin
                q15_to_bf16 = 16'h0000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 16; k = k + 1)
                    if (q15_value[k])
                        msb_index = k;
                exponent_temp = msb_index + 112;
                exponent_biased = exponent_temp[7:0];
                shift_left = 15 - msb_index;
                normalized = {16'd0, q15_value} << shift_left;
                fraction7 = normalized[14:8];
                round_bit = normalized[7];
                sticky_bit = |normalized[6:0];
                rounded_fraction = {1'b0, fraction7};
                if (round_bit && (sticky_bit || fraction7[0]))
                    rounded_fraction = rounded_fraction + 1'b1;
                if (rounded_fraction[7]) begin
                    exponent_biased = exponent_biased + 1'b1;
                    q15_to_bf16 = {1'b0, exponent_biased, 7'd0};
                end else begin
                    q15_to_bf16 = {1'b0, exponent_biased, rounded_fraction[6:0]};
                end
            end
        end
    endfunction

    always_comb begin
        denom_exp_magnitude =
            $signed({max_score[SCORE_W-1], max_score}) -
            $signed({denom_score_reg[SCORE_W-1], denom_score_reg});
        denom_exp_rounded = denom_exp_magnitude + EXP_ROUND_BIAS;
        denom_exp_addr = 10'd0;
        denom_exp_forced_zero = denom_mask_reg;
        if (!denom_exp_forced_zero) begin
            if (denom_exp_magnitude <= 0)
                denom_exp_addr = 10'd0;
            else if (denom_exp_magnitude > EXP_LIMIT_FIXED)
                denom_exp_forced_zero = 1'b1;
            else
                denom_exp_addr = $unsigned(denom_exp_rounded) >> EXP_ADDR_SHIFT;
        end
    end

    always_comb begin
        output_exp_magnitude =
            $signed({max_score[SCORE_W-1], max_score}) -
            $signed({pipe_score_reg[SCORE_W-1], pipe_score_reg});
        output_exp_rounded = output_exp_magnitude + EXP_ROUND_BIAS;
        output_exp_addr = 10'd0;
        output_exp_forced_zero = pipe_mask_reg;
        if (!output_exp_forced_zero) begin
            if (output_exp_magnitude <= 0)
                output_exp_addr = 10'd0;
            else if (output_exp_magnitude > EXP_LIMIT_FIXED)
                output_exp_forced_zero = 1'b1;
            else
                output_exp_addr = $unsigned(output_exp_rounded) >> EXP_ADDR_SHIFT;
        end

        output_probability_rounded = pipe_product_reg + (47'd1 << 29);
        output_probability_q15_ext = output_probability_rounded[46:30];
        if (output_probability_q15_ext > 17'd32768)
            output_probability_q15 = 16'd32768;
        else
            output_probability_q15 = output_probability_q15_ext[15:0];
    end

    always_comb begin
        shared_product = recip_q30 * pipe_exp_value_reg;
    end

    always_comb begin
        if (state == ST_OUTPUT)
            exp_lut_addr = pipe_exp_addr_reg;
        else if (state == ST_DENOM)
            exp_lut_addr = denom_exp_addr_reg;
        else
            exp_lut_addr = 10'd0;
    end

    exp_lut #(.INIT_FILE(EXP_LUT_FILE)) u_exp_lut (
        .addr(exp_lut_addr),
        .data(exp_lut_data)
    );

    assign div_start = (state == ST_RECIP_START) && (sum_exp != '0);
    unsigned_restoring_divider #(
        .NUM_W(RECIP_NUM_W),
        .DEN_W(SUM_W)
    ) u_divider (
        .clk, .rst_n, .start(div_start),
        .numerator(46'd35184372088832),
        .denominator(sum_exp),
        .busy(div_busy), .done(div_done), .divide_by_zero(div_by_zero),
        .quotient(div_quotient), .remainder(div_remainder)
    );

    always_comb begin
        in_ready  = (state == ST_LOAD) && (wr_count < MAX_LEN);
        out_valid = (state == ST_OUTPUT) && pipe_valid[5];
        out_data  = out_valid ? pipe_bf16_reg : 16'h0000;
        out_first = out_valid && pipe_first[5];
        out_last  = out_valid && pipe_last[5];
        out_head  = row_head_reg;
        out_row   = row_index_reg;
        out_col   = pipe_col[5];
        pipe_advance = (state == ST_OUTPUT) && (!pipe_valid[5] || out_ready);
        busy = (state != ST_LOAD) || (wr_count != 0) || have_unmasked ||
               raw_stage_valid || load_stage_valid;
        row_error = out_valid && all_masked_row;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_LOAD;
            wr_count <= '0;
            row_len <= '0;
            max_score <= '0;
            have_unmasked <= 1'b0;
            all_masked_row <= 1'b0;
            sum_exp <= '0;
            recip_q30 <= '0;
            row_head_reg <= '0;
            row_index_reg <= '0;
            metadata_error <= 1'b0;
            raw_stage_valid <= 1'b0;
            raw_stage_data <= '0;
            raw_stage_last <= 1'b0;
            raw_stage_mask <= 1'b0;
            raw_stage_head <= '0;
            raw_stage_row <= '0;
            raw_stage_col <= '0;
            load_stage_valid <= 1'b0;
            load_stage_fixed <= '0;
            load_stage_last <= 1'b0;
            load_stage_mask <= 1'b0;
            load_stage_head <= '0;
            load_stage_row <= '0;
            load_stage_col <= '0;
            denom_pipe_valid <= '0;
            denom_issue_idx <= '0;
            denom_issue_done <= 1'b0;
            denom_score_reg <= '0;
            denom_mask_reg <= 1'b0;
            denom_exp_addr_reg <= '0;
            denom_exp_forced_reg <= 1'b0;
            denom_exp_value_reg <= '0;
            pipe_valid <= '0;
            pipe_score_reg <= '0;
            pipe_mask_reg <= 1'b0;
            pipe_exp_addr_reg <= '0;
            pipe_exp_forced_reg <= 1'b0;
            pipe_exp_value_reg <= '0;
            pipe_product_reg <= '0;
            pipe_q15_reg <= '0;
            pipe_bf16_reg <= '0;
            issue_idx <= '0;
            issue_done <= 1'b0;
            for (pipe_index = 0; pipe_index < 6; pipe_index = pipe_index + 1) begin
                pipe_col[pipe_index] <= '0;
                pipe_first[pipe_index] <= 1'b0;
                pipe_last[pipe_index] <= 1'b0;
            end
        end else begin
            if (state == ST_LOAD) begin
                if (load_stage_valid)
                    load_stage_valid <= 1'b0;
                if (raw_stage_valid) begin
                    raw_stage_valid <= 1'b0;
                    load_stage_valid <= 1'b1;
                    load_stage_fixed <= bf16_to_fixed(raw_stage_data);
                    load_stage_last <= raw_stage_last;
                    load_stage_mask <= raw_stage_mask;
                    load_stage_head <= raw_stage_head;
                    load_stage_row <= raw_stage_row;
                    load_stage_col <= raw_stage_col;
                end
            end

            if (in_valid && in_ready) begin
                raw_stage_valid <= 1'b1;
                raw_stage_data <= in_data;
                raw_stage_last <= in_last;
                raw_stage_mask <= in_mask;
                raw_stage_head <= in_head;
                raw_stage_row <= in_row;
                raw_stage_col <= in_col;
            end

            case (state)
                ST_LOAD: begin
                    if (load_stage_valid) begin
                        score_mem[wr_count[ADDR_W-1:0]] <= load_stage_fixed;
                        mask_mem[wr_count[ADDR_W-1:0]] <= load_stage_mask;
                        if (wr_count == 0) begin
                            row_head_reg <= load_stage_head;
                            row_index_reg <= load_stage_row;
                            metadata_error <= (load_stage_col != 0);
                        end else if ((load_stage_head != row_head_reg) ||
                                     (load_stage_row != row_index_reg) ||
                                     ($unsigned(load_stage_col) != $unsigned(wr_count))) begin
                            metadata_error <= 1'b1;
                        end

                        if (!load_stage_mask) begin
                            if (!have_unmasked || (load_stage_fixed > max_score))
                                max_score <= load_stage_fixed;
                            have_unmasked <= 1'b1;
                        end

                        if (REQUIRE_FULL_ROW && load_stage_last &&
                            (wr_count != MAX_LEN-1))
                            metadata_error <= 1'b1;

                        if (load_stage_last || (wr_count == MAX_LEN-1)) begin
                            if (!load_stage_last)
                                metadata_error <= 1'b1;
                            row_len <= wr_count + 1'b1;
                            all_masked_row <= !(have_unmasked || !load_stage_mask);
                            denom_pipe_valid <= '0;
                            denom_issue_idx <= '0;
                            denom_issue_done <= 1'b0;
                            sum_exp <= '0;
                            state <= ST_DENOM;
                        end else begin
                            wr_count <= wr_count + 1'b1;
                        end
                    end
                end

                ST_DENOM: begin
                    denom_pipe_valid[2] <= denom_pipe_valid[1];
                    denom_pipe_valid[1] <= denom_pipe_valid[0];
                    denom_pipe_valid[0] <= 1'b0;

                    if (denom_pipe_valid[0]) begin
                        denom_exp_addr_reg <= denom_exp_addr;
                        denom_exp_forced_reg <= denom_exp_forced_zero;
                    end
                    if (denom_pipe_valid[1]) begin
                        denom_exp_value_reg <= denom_exp_forced_reg ? 16'd0 :
                                               exp_lut_data;
                    end
                    if (denom_pipe_valid[2])
                        sum_exp <= sum_exp + denom_exp_value_reg;

                    if (!denom_issue_done) begin
                        denom_pipe_valid[0] <= 1'b1;
                        denom_score_reg <= score_mem[denom_issue_idx];
                        denom_mask_reg <= mask_mem[denom_issue_idx];
                        if ($unsigned(denom_issue_idx) ==
                            $unsigned(row_len - 1'b1)) begin
                            denom_issue_done <= 1'b1;
                        end else begin
                            denom_issue_idx <= denom_issue_idx + 1'b1;
                        end
                    end

                    if (denom_issue_done && (denom_pipe_valid == '0))
                        state <= ST_RECIP_START;
                end

                ST_RECIP_START: begin
                    if (sum_exp == '0) begin
                        recip_q30 <= '0;
                        issue_idx <= '0;
                        issue_done <= 1'b0;
                        pipe_valid <= '0;
                        state <= ST_OUTPUT;
                    end else begin
                        state <= ST_RECIP_WAIT;
                    end
                end

                ST_RECIP_WAIT: begin
                    if (div_done) begin
                        recip_q30 <= div_quotient[30:0];
                        issue_idx <= '0;
                        issue_done <= 1'b0;
                        pipe_valid <= '0;
                        state <= ST_OUTPUT;
                    end
                end

                ST_OUTPUT: begin
                    if (pipe_advance) begin
                        for (pipe_index = 5; pipe_index > 0; pipe_index = pipe_index - 1) begin
                            pipe_valid[pipe_index] <= pipe_valid[pipe_index-1];
                            pipe_col[pipe_index] <= pipe_col[pipe_index-1];
                            pipe_first[pipe_index] <= pipe_first[pipe_index-1];
                            pipe_last[pipe_index] <= pipe_last[pipe_index-1];
                        end

                        pipe_exp_addr_reg <= output_exp_addr;
                        pipe_exp_forced_reg <= output_exp_forced_zero;
                        pipe_exp_value_reg <= pipe_exp_forced_reg ? 16'd0 : exp_lut_data;
                        pipe_product_reg <= shared_product;
                        pipe_q15_reg <= output_probability_q15;
                        pipe_bf16_reg <= q15_to_bf16(pipe_q15_reg);

                        if (!issue_done) begin
                            pipe_valid[0] <= 1'b1;
                            pipe_score_reg <= score_mem[issue_idx[ADDR_W-1:0]];
                            pipe_mask_reg <= mask_mem[issue_idx[ADDR_W-1:0]];
                            pipe_col[0] <= issue_idx;
                            pipe_first[0] <= (issue_idx == 0);
                            pipe_last[0] <=
                                ($unsigned(issue_idx) == $unsigned(row_len - 1'b1));
                            if ($unsigned(issue_idx) == $unsigned(row_len - 1'b1))
                                issue_done <= 1'b1;
                            else
                                issue_idx <= issue_idx + 1'b1;
                        end else begin
                            pipe_valid[0] <= 1'b0;
                            pipe_first[0] <= 1'b0;
                            pipe_last[0] <= 1'b0;
                        end
                    end

                    if (out_valid && out_ready && out_last) begin
                        state <= ST_LOAD;
                        wr_count <= '0;
                        row_len <= '0;
                        max_score <= '0;
                        have_unmasked <= 1'b0;
                        all_masked_row <= 1'b0;
                        sum_exp <= '0;
                        recip_q30 <= '0;
                        row_head_reg <= '0;
                        row_index_reg <= '0;
                        metadata_error <= 1'b0;
                        // Preserve raw/load beats that were accepted after
                        // this row's in_last entered the two-stage input
                        // pipeline. They are the start of the next row and
                        // already belong to this module by ready/valid.
                        denom_pipe_valid <= '0;
                        denom_issue_idx <= '0;
                        denom_issue_done <= 1'b0;
                        pipe_valid <= '0;
                        issue_idx <= '0;
                        issue_done <= 1'b0;
                    end
                end

                default: begin
                    state <= ST_LOAD;
                    wr_count <= '0;
                    row_len <= '0;
                    max_score <= '0;
                    have_unmasked <= 1'b0;
                    all_masked_row <= 1'b0;
                    sum_exp <= '0;
                    recip_q30 <= '0;
                    metadata_error <= 1'b1;
                    raw_stage_valid <= 1'b0;
                    load_stage_valid <= 1'b0;
                    denom_pipe_valid <= '0;
                    denom_issue_idx <= '0;
                    denom_issue_done <= 1'b0;
                    pipe_valid <= '0;
                    issue_idx <= '0;
                    issue_done <= 1'b0;
                end
            endcase
        end
    end

    logic unused_div_busy;
    logic unused_div_by_zero;
    logic [SUM_W-1:0] unused_div_remainder;
    assign unused_div_busy = div_busy;
    assign unused_div_by_zero = div_by_zero;
    assign unused_div_remainder = div_remainder;
endmodule
