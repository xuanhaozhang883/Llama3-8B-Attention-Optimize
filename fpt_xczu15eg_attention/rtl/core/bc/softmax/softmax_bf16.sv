`timescale 1ns/1ps

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
    input  logic        rst_n,       // synchronous, active low

    // Input stream. A transfer occurs on in_valid && in_ready.
    input  logic        in_valid,
    output logic        in_ready,
    input  logic [15:0] in_data,     // BF16 attention score
    input  logic        in_last,     // marks the final element of one softmax row
    input  logic        in_mask,     // 1: masked element, 0: valid element
    input  logic [HEAD_W-1:0] in_head,
    input  logic [POS_W-1:0]  in_row,
    input  logic [POS_W-1:0]  in_col,

    // Output stream. All output fields remain stable while out_valid && !out_ready.
    output logic        out_valid,
    input  logic        out_ready,
    output logic [15:0] out_data,    // BF16 probability
    output logic        out_first,
    output logic        out_last,
    output logic [HEAD_W-1:0] out_head,
    output logic [POS_W-1:0]  out_row,
    output logic [POS_W-1:0]  out_col,

    output logic        busy,
    output logic        row_error,       // high during output if the row was all-masked
    output logic        metadata_error   // sticky for the current row
);

    localparam int ADDR_W = (MAX_LEN <= 2) ? 1 : $clog2(MAX_LEN);
    localparam int LEN_W  = (MAX_LEN <= 1) ? 1 : $clog2(MAX_LEN + 1);
    localparam int SUM_W  = 16 + $clog2(MAX_LEN + 1);
    localparam int RECIP_NUM_W = 46;
    localparam int EXP_ADDR_SHIFT = SCORE_FRAC - 6; // LUT step = 1/64
    // Keep EXP address arithmetic at SCORE_W+1 bits.  The previous integer
    // temporary widened this cone to 32 bits even though every accepted
    // magnitude is in [0, 8.0] and therefore rounds into ten address bits.
    localparam logic signed [SCORE_W:0] EXP_LIMIT_FIXED = 8 <<< SCORE_FRAC;
    localparam logic signed [SCORE_W:0] EXP_ROUND_BIAS  =
        1 <<< (EXP_ADDR_SHIFT-1);
    // Eight-bit constants keep the optimized BF16 converter from widening
    // exponent comparisons and subtraction back to 32-bit integer datapaths.
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
        // Keep ST_EXP at numeric value 1 for the existing reset-recovery
        // testbench's hierarchical observation point.  It is now the
        // registered score/mask read stage of the EXP pipeline.
        ST_EXP,
        ST_EXP_ADDR,
        ST_EXP_LUT,
        ST_EXP_ACCUM,
        ST_RECIP_START,
        ST_RECIP_WAIT,
        ST_OUTPUT_MUL,
        ST_OUTPUT_ROUND,
        ST_OUTPUT_CONVERT,
        ST_OUTPUT
    } state_t;

    state_t state;

    // These arrays are intentionally not reset. Every location used by a row is
    // overwritten before it is read, which makes mid-run reset recovery safe and
    // avoids synthesizing thousands of resettable flip-flops. The current
    // score/mask are read into explicit registers before EXP address arithmetic;
    // exp_mem remains behind the registered probability-output pipeline.
    (* ram_style = "distributed" *) logic signed [SCORE_W-1:0] score_mem [0:MAX_LEN-1];
    (* ram_style = "distributed" *) logic                      mask_mem  [0:MAX_LEN-1];
    (* ram_style = "distributed" *) logic [15:0]               exp_mem   [0:MAX_LEN-1]; // unsigned Q1.15

    logic [LEN_W-1:0] wr_count;
    logic [LEN_W-1:0] row_len;
    logic [ADDR_W-1:0] proc_idx;
    logic [ADDR_W-1:0] out_idx;

    logic signed [SCORE_W-1:0] max_score;
    logic have_unmasked;
    logic all_masked_row;

    logic [HEAD_W-1:0] row_head_reg;
    logic [POS_W-1:0]  row_index_reg;

    logic [SUM_W-1:0] sum_exp;
    logic [30:0] recip_q30;

    // Two elastic input stages separate the Row Tile Buffer BRAM output, the
    // BF16 conversion, and max_score into different cycles.  Without these
    // registers Vivado placed the complete conversion and signed max comparison
    // in one cycle (44 logic levels and 19.316 ns on xc7a35t-1).
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

    logic signed [SCORE_W:0] exp_magnitude;
    logic signed [SCORE_W:0] exp_rounded_magnitude;
    logic [9:0] exp_addr;
    logic exp_forced_zero;
    logic [15:0] exp_lut_data;
    logic signed [SCORE_W-1:0] exp_score_reg;
    logic                      exp_mask_reg;
    logic [9:0]                exp_addr_reg;
    logic                      exp_forced_zero_reg;
    logic [15:0]               exp_value_reg;

    logic div_start;
    logic div_busy;
    logic div_done;
    logic div_by_zero;
    logic [RECIP_NUM_W-1:0] div_quotient;
    logic [SUM_W-1:0] div_remainder;

    // The probability output path is intentionally split across three
    // registered arithmetic stages.  This prevents the distributed exp RAM,
    // DSP multiply, rounding adder and Q15-to-BF16 encoder from forming one
    // long combinational path into the P Buffer.
    logic [46:0] probability_product;
    logic [46:0] probability_product_reg;
    logic [46:0] probability_rounded;
    logic [16:0] probability_q15_ext;
    logic [15:0] probability_q15;
    logic [15:0] probability_q15_reg;
    logic [15:0] out_data_reg;

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
                // Zero and BF16 subnormals are below the useful score resolution here.
                bf16_to_fixed = '0;
            end else if (exponent == 8'hff) begin
                // Infinity saturates. NaN is mapped to zero.
                if (fraction != 7'd0)
                    bf16_to_fixed = '0;
                else
                    bf16_to_fixed = sign_bit ?
                        {1'b1, {(SCORE_W-1){1'b0}}} :
                        {1'b0, {(SCORE_W-1){1'b1}}};
            end else if (exponent >= BF16_SAT_EXP) begin
                // Values at or above this exponent exceed the Q format.  The
                // negative limit has one additional representable magnitude.
                bf16_to_fixed = sign_bit ?
                    {1'b1, {(SCORE_W-1){1'b0}}} :
                    {1'b0, {(SCORE_W-1){1'b1}}};
            end else if (exponent <= BF16_ZERO_EXP) begin
                // An eight-bit significand rounded right by nine or more bits
                // is exactly zero.  Handling it explicitly removes the former
                // 64-bit variable shifter and saturation comparators.
                bf16_to_fixed = '0;
            end else begin
                // fixed = significand * 2^(exponent - 127 - 7 + SCORE_FRAC)
                if (exponent >= BF16_SHIFT_BIAS) begin
                    left_shift = exponent - BF16_SHIFT_BIAS;
                    magnitude = {{(SCORE_W-8){1'b0}}, significand} << left_shift;
                end else begin
                    right_shift = BF16_SHIFT_BIAS - exponent;
                    // Match the legacy round-to-nearest conversion exactly.
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

                exponent_temp = msb_index + 112; // 127 + msb_index - 15
                exponent_biased = exponent_temp[7:0];
                shift_left = 15 - msb_index;
                normalized = {16'd0, q15_value} << shift_left;

                fraction7 = normalized[14:8];
                round_bit = normalized[7];
                sticky_bit = |normalized[6:0];
                rounded_fraction = {1'b0, fraction7};

                // Round to nearest, ties to even.
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
        exp_magnitude = $signed({max_score[SCORE_W-1], max_score}) -
                        $signed({exp_score_reg[SCORE_W-1], exp_score_reg});
        exp_rounded_magnitude = exp_magnitude + EXP_ROUND_BIAS;

        exp_addr = 10'd0;
        exp_forced_zero = 1'b0;

        if (exp_mask_reg) begin
            exp_forced_zero = 1'b1;
        end else if (exp_magnitude <= 0) begin
            exp_addr = 10'd0;
        end else if (exp_magnitude > EXP_LIMIT_FIXED) begin
            exp_forced_zero = 1'b1;
        end else begin
            // Round magnitude to the nearest 1/64 step.
            // The <=8.0 guard proves the rounded result is <=512, so the old
            // 32-bit clamp is redundant.
            exp_addr = $unsigned(exp_rounded_magnitude) >> EXP_ADDR_SHIFT;
        end
    end

    exp_lut #(
        .INIT_FILE(EXP_LUT_FILE)
    ) u_exp_lut (
        .addr(exp_addr_reg),
        .data(exp_lut_data)
    );

    assign div_start = (state == ST_RECIP_START) && (sum_exp != '0);

    unsigned_restoring_divider #(
        .NUM_W(RECIP_NUM_W),
        .DEN_W(SUM_W)
    ) u_divider (
        .clk(clk),
        .rst_n(rst_n),
        .start(div_start),
        .numerator(46'd35184372088832), // 2^45; gives reciprocal in unsigned Q1.30
        .denominator(sum_exp),
        .busy(div_busy),
        .done(div_done),
        .divide_by_zero(div_by_zero),
        .quotient(div_quotient),
        .remainder(div_remainder)
    );

    always_comb begin
        probability_product = exp_mem[out_idx] * recip_q30;
        probability_rounded = probability_product_reg + (47'd1 << 29);
        probability_q15_ext = probability_rounded[46:30];

        if (probability_q15_ext > 17'd32768)
            probability_q15 = 16'd32768;
        else
            probability_q15 = probability_q15_ext[15:0];
    end

    always_comb begin
        // Both input stages advance every ST_LOAD cycle and can be refilled on
        // the same edge, preserving one input beat/cycle after pipeline fill.
        in_ready  = (state == ST_LOAD) && (wr_count < MAX_LEN);
        out_valid = (state == ST_OUTPUT);
        out_first = (state == ST_OUTPUT) && (out_idx == 0);
        out_last  = (state == ST_OUTPUT) && (out_idx == row_len - 1'b1);
        out_data  = (state == ST_OUTPUT) ? out_data_reg : 16'h0000;
        out_head  = row_head_reg;
        out_row   = row_index_reg;
        out_col   = out_idx;
        busy      = (state != ST_LOAD) || (wr_count != 0) || have_unmasked ||
                    raw_stage_valid || load_stage_valid;
        row_error = (state == ST_OUTPUT) && all_masked_row;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state           <= ST_LOAD;
            wr_count        <= '0;
            row_len         <= '0;
            proc_idx        <= '0;
            out_idx         <= '0;
            max_score       <= '0;
            have_unmasked   <= 1'b0;
            all_masked_row  <= 1'b0;
            sum_exp         <= '0;
            recip_q30       <= '0;
            row_head_reg     <= '0;
            row_index_reg    <= '0;
            metadata_error   <= 1'b0;
            raw_stage_valid  <= 1'b0;
            raw_stage_data   <= '0;
            raw_stage_last   <= 1'b0;
            raw_stage_mask   <= 1'b0;
            raw_stage_head   <= '0;
            raw_stage_row    <= '0;
            raw_stage_col    <= '0;
            load_stage_valid <= 1'b0;
            load_stage_fixed <= '0;
            load_stage_last  <= 1'b0;
            load_stage_mask  <= 1'b0;
            load_stage_head  <= '0;
            load_stage_row   <= '0;
            load_stage_col   <= '0;
            exp_score_reg    <= '0;
            exp_mask_reg     <= 1'b0;
            exp_addr_reg     <= '0;
            exp_forced_zero_reg <= 1'b0;
            exp_value_reg    <= '0;
            probability_product_reg <= '0;
            probability_q15_reg     <= '0;
            out_data_reg            <= '0;
        end else begin
            // During ST_LOAD the fixed stage is consumed, the raw stage is
            // converted into its replacement, and the port may refill the raw
            // stage.  Assignment order intentionally makes refill win.
            if (state == ST_LOAD) begin
                if (load_stage_valid)
                    load_stage_valid <= 1'b0;
                if (raw_stage_valid) begin
                    raw_stage_valid  <= 1'b0;
                    load_stage_valid <= 1'b1;
                    load_stage_fixed <= bf16_to_fixed(raw_stage_data);
                    load_stage_last  <= raw_stage_last;
                    load_stage_mask  <= raw_stage_mask;
                    load_stage_head  <= raw_stage_head;
                    load_stage_row   <= raw_stage_row;
                    load_stage_col   <= raw_stage_col;
                end
            end

            if (in_valid && in_ready) begin
                raw_stage_valid <= 1'b1;
                raw_stage_data  <= in_data;
                raw_stage_last  <= in_last;
                raw_stage_mask  <= in_mask;
                raw_stage_head  <= in_head;
                raw_stage_row   <= in_row;
                raw_stage_col   <= in_col;
            end

            case (state)
                ST_LOAD: begin
                    if (load_stage_valid) begin
                        score_mem[wr_count[ADDR_W-1:0]] <= load_stage_fixed;
                        mask_mem[wr_count[ADDR_W-1:0]]  <= load_stage_mask;

                        if (wr_count == 0) begin
                            row_head_reg    <= load_stage_head;
                            row_index_reg   <= load_stage_row;
                            metadata_error  <= 1'b0;
                            if (load_stage_col != 0)
                                metadata_error <= 1'b1;
                        end else begin
                            if ((load_stage_head != row_head_reg) ||
                                (load_stage_row  != row_index_reg) ||
                                ($unsigned(load_stage_col) != $unsigned(wr_count)))
                                metadata_error <= 1'b1;
                        end

                        if (!load_stage_mask) begin
                            if (!have_unmasked || (load_stage_fixed > max_score))
                                max_score <= load_stage_fixed;
                            have_unmasked <= 1'b1;
                        end

                        // The project adapter sends exactly MAX_LEN elements per row.
                        // Flag an early in_last, and if the marker is missing at MAX_LEN,
                        // force closure instead of deadlocking forever.
                        if (REQUIRE_FULL_ROW && load_stage_last &&
                            (wr_count != MAX_LEN-1))
                            metadata_error <= 1'b1;

                        if (load_stage_last || (wr_count == MAX_LEN-1)) begin
                            if (!load_stage_last)
                                metadata_error <= 1'b1;
                            row_len        <= wr_count + 1'b1;
                            proc_idx       <= '0;
                            sum_exp        <= '0;
                            all_masked_row <= !(have_unmasked || !load_stage_mask);
                            state          <= ST_EXP;
                        end else begin
                            wr_count <= wr_count + 1'b1;
                        end
                    end
                end

                ST_EXP: begin
                    // Stage 1: isolate the distributed score/mask memory read
                    // from subtraction, LUT decoding, and accumulation.
                    exp_score_reg <= score_mem[proc_idx];
                    exp_mask_reg  <= mask_mem[proc_idx];
                    state         <= ST_EXP_ADDR;
                end

                ST_EXP_ADDR: begin
                    // Stage 2: register the rounded/clamped EXP LUT address.
                    // max_score and proc_idx remain stable throughout the four
                    // EXP states, so the captured score stays aligned.
                    exp_addr_reg        <= exp_addr;
                    exp_forced_zero_reg <= exp_forced_zero;
                    state               <= ST_EXP_LUT;
                end

                ST_EXP_LUT: begin
                    // Stage 3: isolate LUT decode from the 24-bit row sum.
                    exp_value_reg <= exp_forced_zero_reg ? 16'd0 : exp_lut_data;
                    state         <= ST_EXP_ACCUM;
                end

                ST_EXP_ACCUM: begin
                    // Stage 4: write the aligned EXP value and update the sum.
                    exp_mem[proc_idx] <= exp_value_reg;
                    sum_exp <= sum_exp + exp_value_reg;

                    if (proc_idx == row_len - 1'b1) begin
                        state <= ST_RECIP_START;
                    end else begin
                        proc_idx <= proc_idx + 1'b1;
                        state    <= ST_EXP;
                    end
                end

                ST_RECIP_START: begin
                    if (sum_exp == '0) begin
                        recip_q30 <= '0;
                        out_idx   <= '0;
                        state     <= ST_OUTPUT_MUL;
                    end else begin
                        state <= ST_RECIP_WAIT;
                    end
                end

                ST_RECIP_WAIT: begin
                    if (div_done) begin
                        recip_q30 <= div_quotient[30:0];
                        out_idx   <= '0;
                        state     <= ST_OUTPUT_MUL;
                    end
                end

                ST_OUTPUT_MUL: begin
                    probability_product_reg <= probability_product;
                    state <= ST_OUTPUT_ROUND;
                end

                ST_OUTPUT_ROUND: begin
                    probability_q15_reg <= probability_q15;
                    state <= ST_OUTPUT_CONVERT;
                end

                ST_OUTPUT_CONVERT: begin
                    out_data_reg <= q15_to_bf16(probability_q15_reg);
                    state <= ST_OUTPUT;
                end

                ST_OUTPUT: begin
                    if (out_valid && out_ready) begin
                        if (out_idx == row_len - 1'b1) begin
                            state           <= ST_LOAD;
                            wr_count        <= '0;
                            row_len         <= '0;
                            proc_idx        <= '0;
                            out_idx         <= '0;
                            max_score       <= '0;
                            have_unmasked   <= 1'b0;
                            all_masked_row  <= 1'b0;
                            sum_exp         <= '0;
                            recip_q30       <= '0;
                            exp_score_reg   <= '0;
                            exp_mask_reg    <= 1'b0;
                            exp_addr_reg    <= '0;
                            exp_forced_zero_reg <= 1'b0;
                            exp_value_reg   <= '0;
                            probability_product_reg <= '0;
                            probability_q15_reg     <= '0;
                            out_data_reg            <= '0;
                            row_head_reg     <= '0;
                            row_index_reg    <= '0;
                            metadata_error   <= 1'b0;
                        end else begin
                            out_idx <= out_idx + 1'b1;
                            state   <= ST_OUTPUT_MUL;
                        end
                    end
                end

                default: begin
                    state           <= ST_LOAD;
                    wr_count        <= '0;
                    row_len         <= '0;
                    proc_idx        <= '0;
                    out_idx         <= '0;
                    max_score       <= '0;
                    have_unmasked   <= 1'b0;
                    all_masked_row  <= 1'b0;
                    sum_exp         <= '0;
                    recip_q30       <= '0;
                    exp_score_reg   <= '0;
                    exp_mask_reg    <= 1'b0;
                    exp_addr_reg    <= '0;
                    exp_forced_zero_reg <= 1'b0;
                    exp_value_reg   <= '0;
                    probability_product_reg <= '0;
                    probability_q15_reg     <= '0;
                    out_data_reg            <= '0;
                    row_head_reg    <= '0;
                    row_index_reg   <= '0;
                    metadata_error  <= 1'b1;
                    raw_stage_valid <= 1'b0;
                    load_stage_valid <= 1'b0;
                end
            endcase
        end
    end

endmodule
