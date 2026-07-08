module softmax_bf16 #(
    parameter int MAX_LEN    = 32,
    parameter int SCORE_W    = 24,
    parameter int SCORE_FRAC = 14,
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

    // Output stream. out_data/out_last remain stable while out_valid && !out_ready.
    output logic        out_valid,
    input  logic        out_ready,
    output logic [15:0] out_data,    // BF16 probability
    output logic        out_last,

    output logic        busy,
    output logic        row_error    // high during output if the row was all-masked
);

    localparam int ADDR_W = (MAX_LEN <= 2) ? 1 : $clog2(MAX_LEN);
    localparam int LEN_W  = (MAX_LEN <= 1) ? 1 : $clog2(MAX_LEN + 1);
    localparam int SUM_W  = 16 + $clog2(MAX_LEN + 1);
    localparam int RECIP_NUM_W = 46;
    localparam int EXP_ADDR_SHIFT = SCORE_FRAC - 6; // LUT step = 1/64

    initial begin
        if (MAX_LEN < 1)
            $error("MAX_LEN must be >= 1");
        if (SCORE_FRAC < 7)
            $error("SCORE_FRAC must be >= 7");
    end

    typedef enum logic [2:0] {
        ST_LOAD,
        ST_EXP,
        ST_RECIP_START,
        ST_RECIP_WAIT,
        ST_OUTPUT
    } state_t;

    state_t state;

    logic signed [SCORE_W-1:0] score_mem [0:MAX_LEN-1];
    logic                      mask_mem  [0:MAX_LEN-1];
    logic [15:0]               exp_mem   [0:MAX_LEN-1]; // unsigned Q1.15

    logic [LEN_W-1:0] wr_count;
    logic [LEN_W-1:0] row_len;
    logic [ADDR_W-1:0] proc_idx;
    logic [ADDR_W-1:0] out_idx;

    logic signed [SCORE_W-1:0] max_score;
    logic have_unmasked;
    logic all_masked_row;

    logic [SUM_W-1:0] sum_exp;
    logic [30:0] recip_q30;

    logic signed [SCORE_W-1:0] in_fixed;

    logic signed [SCORE_W:0] exp_magnitude;
    logic [9:0] exp_addr;
    logic exp_forced_zero;
    logic [15:0] exp_lut_data;
    logic [15:0] exp_current;

    logic div_start;
    logic div_busy;
    logic div_done;
    logic div_by_zero;
    logic [RECIP_NUM_W-1:0] div_quotient;
    logic [SUM_W-1:0] div_remainder;

    logic [46:0] probability_product;
    logic [46:0] probability_rounded;
    logic [16:0] probability_q15_ext;
    logic [15:0] probability_q15;

    integer i;

    function automatic logic signed [SCORE_W-1:0] bf16_to_fixed(
        input logic [15:0] value_bf16
    );
        logic sign_bit;
        logic [7:0] exponent;
        logic [6:0] fraction;
        logic [7:0] significand;
        logic signed [63:0] significand_64;
        logic signed [63:0] magnitude;
        logic signed [63:0] signed_value;
        logic signed [63:0] max_value;
        logic signed [63:0] min_value;
        integer shift_amount;
        integer right_shift;
        begin
            sign_bit   = value_bf16[15];
            exponent   = value_bf16[14:7];
            fraction   = value_bf16[6:0];
            significand = {1'b1, fraction};
            significand_64 = $signed({56'd0, significand});
            max_value  = (64'sd1 <<< (SCORE_W-1)) - 1;
            min_value  = -(64'sd1 <<< (SCORE_W-1));
            magnitude  = 64'sd0;

            if (exponent == 8'h00) begin
                // Zero and BF16 subnormals are below the useful score resolution here.
                signed_value = 64'sd0;
            end else if (exponent == 8'hff) begin
                // Infinity saturates. NaN is mapped to zero.
                if (fraction != 7'd0)
                    signed_value = 64'sd0;
                else
                    signed_value = sign_bit ? min_value : max_value;
            end else begin
                // fixed = significand * 2^(exponent - 127 - 7 + SCORE_FRAC)
                shift_amount = $signed({1'b0, exponent}) + SCORE_FRAC - 134;

                if (shift_amount >= (SCORE_W - 8)) begin
                    magnitude = max_value + 1;
                end else if (shift_amount >= 0) begin
                    magnitude = significand_64 <<< shift_amount;
                end else begin
                    right_shift = -shift_amount;
                    if (right_shift >= 63) begin
                        magnitude = 64'sd0;
                    end else if (right_shift == 0) begin
                        magnitude = significand_64;
                    end else begin
                        // Round to nearest for the BF16-to-fixed conversion.
                        magnitude = (significand_64 +
                                     (64'sd1 <<< (right_shift-1))) >>> right_shift;
                    end
                end

                signed_value = sign_bit ? -magnitude : magnitude;
                if (signed_value > max_value)
                    signed_value = max_value;
                else if (signed_value < min_value)
                    signed_value = min_value;
            end

            bf16_to_fixed = signed_value[SCORE_W-1:0];
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
        begin
            if (q15_value == 16'd0) begin
                q15_to_bf16 = 16'h0000;
            end else begin
                msb_index = 0;
                for (k = 0; k < 16; k = k + 1)
                    if (q15_value[k])
                        msb_index = k;

                exponent_biased = msb_index + 112; // 127 + msb_index - 15
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

    assign in_fixed = bf16_to_fixed(in_data);

    always_comb begin
        exp_magnitude = $signed({max_score[SCORE_W-1], max_score}) -
                        $signed({score_mem[proc_idx][SCORE_W-1], score_mem[proc_idx]});

        exp_addr = 10'd0;
        exp_forced_zero = 1'b0;

        if (mask_mem[proc_idx]) begin
            exp_forced_zero = 1'b1;
        end else if (exp_magnitude <= 0) begin
            exp_addr = 10'd0;
        end else if (exp_magnitude > (8 <<< SCORE_FRAC)) begin
            exp_forced_zero = 1'b1;
        end else begin
            // Round magnitude to the nearest 1/64 step.
            exp_addr = (exp_magnitude + (1 <<< (EXP_ADDR_SHIFT-1))) >>> EXP_ADDR_SHIFT;
            if (exp_addr > 10'd512)
                exp_addr = 10'd512;
        end
    end

    exp_lut #(
        .INIT_FILE(EXP_LUT_FILE)
    ) u_exp_lut (
        .addr(exp_addr),
        .data(exp_lut_data)
    );

    assign exp_current = exp_forced_zero ? 16'd0 : exp_lut_data;

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
        probability_rounded = probability_product + (47'd1 << 29);
        probability_q15_ext = probability_rounded >> 30;

        if (probability_q15_ext > 17'd32768)
            probability_q15 = 16'd32768;
        else
            probability_q15 = probability_q15_ext[15:0];
    end

    always_comb begin
        in_ready  = (state == ST_LOAD) && (wr_count < MAX_LEN);
        out_valid = (state == ST_OUTPUT);
        out_last  = (state == ST_OUTPUT) && (out_idx == row_len - 1'b1);
        out_data  = (state == ST_OUTPUT) ? q15_to_bf16(probability_q15) : 16'h0000;
        busy      = (state != ST_LOAD) || (wr_count != 0) || have_unmasked;
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

            for (i = 0; i < MAX_LEN; i = i + 1) begin
                score_mem[i] <= '0;
                mask_mem[i]  <= 1'b1;
                exp_mem[i]   <= '0;
            end
        end else begin
            case (state)
                ST_LOAD: begin
                    if (in_valid && in_ready) begin
                        score_mem[wr_count[ADDR_W-1:0]] <= in_fixed;
                        mask_mem[wr_count[ADDR_W-1:0]]  <= in_mask;

                        if (!in_mask) begin
                            if (!have_unmasked || (in_fixed > max_score))
                                max_score <= in_fixed;
                            have_unmasked <= 1'b1;
                        end

                        if (in_last) begin
                            row_len        <= wr_count + 1'b1;
                            proc_idx       <= '0;
                            sum_exp        <= '0;
                            all_masked_row <= !(have_unmasked || !in_mask);
                            state          <= ST_EXP;
                        end else begin
                            wr_count <= wr_count + 1'b1;
                        end
                    end
                end

                ST_EXP: begin
                    exp_mem[proc_idx] <= exp_current;
                    sum_exp <= sum_exp + exp_current;

                    if (proc_idx == row_len - 1'b1) begin
                        state <= ST_RECIP_START;
                    end else begin
                        proc_idx <= proc_idx + 1'b1;
                    end
                end

                ST_RECIP_START: begin
                    if (sum_exp == '0) begin
                        recip_q30 <= '0;
                        out_idx   <= '0;
                        state     <= ST_OUTPUT;
                    end else begin
                        state <= ST_RECIP_WAIT;
                    end
                end

                ST_RECIP_WAIT: begin
                    if (div_done) begin
                        recip_q30 <= div_quotient[30:0];
                        out_idx   <= '0;
                        state     <= ST_OUTPUT;
                    end
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
                        end else begin
                            out_idx <= out_idx + 1'b1;
                        end
                    end
                end

                default: begin
                    state <= ST_LOAD;
                end
            endcase
        end
    end

endmodule
