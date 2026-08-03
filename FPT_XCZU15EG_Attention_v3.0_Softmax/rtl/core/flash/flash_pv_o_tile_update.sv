`timescale 1ns/1ps

// FlashAttention Stage 3A: one 4x8 Context-numerator update.
//
// For each query row r and V feature lane d:
//   O_new[r,d] = alpha[r] * O_old[r,d]
//                + sum_k(P[r,k] * V[k,d]), k=0..3
//
// P and alpha are unsigned Q1.23 from Stage 2B. V is converted from BF16 to
// signed Q6.11. O is a signed 40-bit Q20.19 numerator and is not divided by l
// until the complete attention row finishes. A 32-lane multiplier array is
// reused for alpha and the four reduction terms. Operand, multiplier, scale,
// and accumulation registers isolate every wide arithmetic stage, so one block
// completes in eight cycles while V_LANES=8 is processed in parallel.
module flash_pv_o_tile_update #(
    parameter integer TILE        = 4,
    parameter integer V_LANES     = 8,
    parameter integer EXP_W       = 24,
    parameter integer EXP_FRAC    = 23,
    parameter integer V_FIXED_W   = 18,
    parameter integer V_FRAC      = 11,
    parameter integer O_ACC_W     = 40,
    parameter integer O_FRAC      = 19
) (
    input  logic                            clk,
    input  logic                            rst_n,

    input  logic                            in_valid,
    output logic                            in_ready,
    input  logic [TILE-1:0]                 in_new_state_valid,
    input  logic [TILE-1:0]                 in_old_o_valid,
    input  logic [TILE*EXP_W-1:0]           in_alpha_q23,
    input  logic [TILE*TILE*EXP_W-1:0]      in_weights_q23,
    input  logic [TILE*V_LANES*16-1:0]      in_v_tile_bf16,
    input  logic [TILE*V_LANES*O_ACC_W-1:0] in_old_o_fixed,

    output logic                            out_valid,
    input  logic                            out_ready,
    output logic [TILE-1:0]                 out_o_valid,
    output logic [TILE*V_LANES*O_ACC_W-1:0] out_o_fixed,
    output logic [TILE-1:0]                 out_numeric_error,
    output logic                            busy
);

    localparam integer OUT_ELEMS = TILE*V_LANES;
    localparam integer ISSUE_STEPS = TILE + 1;
    localparam integer ISSUE_W = $clog2(ISSUE_STEPS + 1);
    localparam integer COEFF_SIGNED_W = EXP_W + 1;
    localparam integer PRODUCT_W = COEFF_SIGNED_W + O_ACC_W;
    localparam integer PV_TO_O_SHIFT = EXP_FRAC + V_FRAC - O_FRAC;
    localparam integer PV_INPUT_ALIGN = EXP_FRAC - PV_TO_O_SHIFT;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_RUN,
        ST_HOLD
    } state_t;

    state_t state;

    logic [TILE-1:0] new_state_valid_reg;
    logic [TILE-1:0] old_o_valid_reg;
    logic [TILE*EXP_W-1:0] alpha_reg;
    logic [TILE*TILE*EXP_W-1:0] weights_reg;
    logic [TILE*V_LANES*16-1:0] v_tile_reg;
    logic [TILE*V_LANES*O_ACC_W-1:0] old_o_reg;

    logic signed [O_ACC_W-1:0] o_acc_reg [0:OUT_ELEMS-1];
    logic signed [COEFF_SIGNED_W-1:0] operand_coeff_reg [0:TILE-1];
    logic signed [O_ACC_W-1:0] operand_data_reg [0:OUT_ELEMS-1];
    logic operand_valid;
    logic operand_alpha_path;
    logic operand_last;
    logic [TILE-1:0] operand_error;

    logic signed [PRODUCT_W-1:0] product_pipe [0:OUT_ELEMS-1];
    logic product_valid;
    logic product_alpha_path;
    logic product_last;
    logic [TILE-1:0] product_error;

    logic signed [O_ACC_W-1:0] scaled_pipe [0:OUT_ELEMS-1];
    logic scaled_valid;
    logic scaled_alpha_path;
    logic scaled_last;
    logic [TILE-1:0] scaled_error;
    logic [TILE-1:0] error_reg;
    logic [ISSUE_W-1:0] issue_count;

    logic [V_FIXED_W:0] v_status [0:V_LANES-1];
    logic signed [V_FIXED_W-1:0] v_fixed [0:V_LANES-1];
    logic [V_LANES-1:0] v_error;
    logic [1:0] issue_k;

    logic [O_ACC_W:0] product_scaled_status [0:OUT_ELEMS-1];
    logic signed [O_ACC_W-1:0] product_scaled [0:OUT_ELEMS-1];
    logic [O_ACC_W:0] add_status [0:OUT_ELEMS-1];
    logic signed [O_ACC_W-1:0] acc_candidate [0:OUT_ELEMS-1];
    logic [TILE-1:0] product_saturation_by_row;
    logic [TILE-1:0] add_saturation_by_row;

    function automatic logic [V_FIXED_W:0] bf16_to_vfixed_status(
        input logic [15:0] value_bf16
    );
        logic sign_bit;
        logic [7:0] exponent;
        logic [6:0] fraction;
        logic [7:0] significand;
        logic [V_FIXED_W:0] magnitude;
        logic [V_FIXED_W:0] quotient;
        logic [V_FIXED_W:0] remainder;
        logic [V_FIXED_W:0] half_value;
        logic round_up;
        logic range_error;
        integer shift_amount;
        integer right_shift;
        logic signed [V_FIXED_W:0] signed_value;
        logic signed [V_FIXED_W-1:0] result_value;
        begin
            sign_bit = value_bf16[15];
            exponent = value_bf16[14:7];
            fraction = value_bf16[6:0];
            significand = {1'b1, fraction};
            magnitude = '0;
            quotient = '0;
            remainder = '0;
            half_value = '0;
            round_up = 1'b0;
            range_error = 1'b0;
            shift_amount = 0;
            right_shift = 0;
            signed_value = '0;
            result_value = '0;

            if (exponent == 8'h00) begin
                result_value = '0;
            end else if (exponent == 8'hff) begin
                range_error = 1'b1;
                if (sign_bit)
                    result_value = {1'b1, {(V_FIXED_W-1){1'b0}}};
                else
                    result_value = {1'b0, {(V_FIXED_W-1){1'b1}}};
            end else begin
                // fixed = significand * 2^(exponent-127+V_FRAC-7)
                shift_amount = $signed({1'b0, exponent}) -
                               (134 - V_FRAC);
                if (shift_amount >= 0) begin
                    if (shift_amount >= V_FIXED_W) begin
                        magnitude = {V_FIXED_W+1{1'b1}};
                    end else begin
                        magnitude =
                            {{(V_FIXED_W-7){1'b0}}, significand} <<
                            shift_amount;
                    end
                end else begin
                    right_shift = -shift_amount;
                    if (right_shift > 8) begin
                        magnitude = '0;
                    end else begin
                        quotient = significand >> right_shift;
                        remainder = significand &
                            ((1 << right_shift) - 1);
                        half_value = 1 << (right_shift - 1);
                        round_up = (remainder > half_value) ||
                            ((remainder == half_value) && quotient[0]);
                        magnitude = quotient + round_up;
                    end
                end

                if (!sign_bit &&
                    (magnitude > ((1 << (V_FIXED_W-1)) - 1))) begin
                    result_value = {1'b0, {(V_FIXED_W-1){1'b1}}};
                    range_error = 1'b1;
                end else if (sign_bit &&
                             (magnitude > (1 << (V_FIXED_W-1)))) begin
                    result_value = {1'b1, {(V_FIXED_W-1){1'b0}}};
                    range_error = 1'b1;
                end else if (sign_bit) begin
                    signed_value = -$signed(magnitude);
                    result_value = signed_value[V_FIXED_W-1:0];
                end else begin
                    result_value = magnitude[V_FIXED_W-1:0];
                end
            end

            bf16_to_vfixed_status = {range_error, result_value};
        end
    endfunction

    function automatic logic [O_ACC_W:0] product_to_o_status(
        input logic signed [PRODUCT_W-1:0] value
    );
        logic negative;
        logic [PRODUCT_W:0] magnitude;
        logic [PRODUCT_W:0] quotient;
        logic [PRODUCT_W:0] remainder;
        logic [PRODUCT_W:0] half_value;
        logic [PRODUCT_W:0] remainder_mask;
        logic round_up;
        logic range_error;
        logic [PRODUCT_W:0] positive_limit;
        logic [PRODUCT_W:0] negative_limit;
        logic signed [PRODUCT_W:0] signed_rounded;
        logic signed [O_ACC_W-1:0] result_value;
        begin
            negative = value[PRODUCT_W-1];
            magnitude = negative ? -$signed({value[PRODUCT_W-1], value}) :
                                   $unsigned({1'b0, value});
            quotient = '0;
            remainder = '0;
            half_value = '0;
            remainder_mask = '0;
            round_up = 1'b0;
            range_error = 1'b0;
            positive_limit = '0;
            negative_limit = '0;
            signed_rounded = '0;
            result_value = '0;
            quotient = magnitude >> EXP_FRAC;
            half_value[EXP_FRAC-1] = 1'b1;
            remainder_mask = (half_value << 1) - 1'b1;
            remainder = magnitude & remainder_mask;
            round_up = (remainder > half_value) ||
                       ((remainder == half_value) && quotient[0]);
            quotient = quotient + round_up;

            positive_limit[O_ACC_W-1:0] =
                {1'b0, {(O_ACC_W-1){1'b1}}};
            negative_limit[O_ACC_W-1] = 1'b1;

            if (!negative &&
                (quotient > positive_limit)) begin
                result_value = {1'b0, {(O_ACC_W-1){1'b1}}};
                range_error = 1'b1;
            end else if (negative &&
                         (quotient > negative_limit)) begin
                result_value = {1'b1, {(O_ACC_W-1){1'b0}}};
                range_error = 1'b1;
            end else if (negative) begin
                signed_rounded = -$signed(quotient);
                result_value = signed_rounded[O_ACC_W-1:0];
            end else begin
                result_value = quotient[O_ACC_W-1:0];
            end

            product_to_o_status = {range_error, result_value};
        end
    endfunction

    function automatic logic [O_ACC_W:0] sat_add_status(
        input logic signed [O_ACC_W-1:0] a,
        input logic signed [O_ACC_W-1:0] b
    );
        logic signed [O_ACC_W:0] sum_ext;
        logic signed [O_ACC_W:0] max_ext;
        logic signed [O_ACC_W:0] min_ext;
        logic signed [O_ACC_W-1:0] result_value;
        logic range_error;
        begin
            sum_ext = $signed({a[O_ACC_W-1], a}) +
                      $signed({b[O_ACC_W-1], b});
            max_ext = $signed({2'b00, {(O_ACC_W-1){1'b1}}});
            min_ext = $signed({2'b11, {(O_ACC_W-1){1'b0}}});
            range_error = 1'b0;
            if (sum_ext > max_ext) begin
                result_value = {1'b0, {(O_ACC_W-1){1'b1}}};
                range_error = 1'b1;
            end else if (sum_ext < min_ext) begin
                result_value = {1'b1, {(O_ACC_W-1){1'b0}}};
                range_error = 1'b1;
            end else begin
                result_value = sum_ext[O_ACC_W-1:0];
            end
            sat_add_status = {range_error, result_value};
        end
    endfunction

    assign in_ready = rst_n && (state == ST_IDLE) && !out_valid;
    assign busy = (state != ST_IDLE) || out_valid;
    assign issue_k = (issue_count == 0) ? 2'd0 : issue_count - 1'b1;

    integer v_lane;
    always @* begin
        for (v_lane = 0; v_lane < V_LANES;
             v_lane = v_lane + 1) begin
            v_status[v_lane] = bf16_to_vfixed_status(
                v_tile_reg[
                    (issue_k*V_LANES + v_lane)*16 +: 16]);
            v_fixed[v_lane] =
                $signed(v_status[v_lane][V_FIXED_W-1:0]);
            v_error[v_lane] = v_status[v_lane][V_FIXED_W];
        end
    end

    integer scale_index;
    integer scale_row;
    always @* begin
        product_saturation_by_row = '0;
        for (scale_index = 0; scale_index < OUT_ELEMS;
             scale_index = scale_index + 1) begin
            product_scaled_status[scale_index] =
                product_to_o_status(product_pipe[scale_index]);
            product_scaled[scale_index] = $signed(
                product_scaled_status[scale_index][O_ACC_W-1:0]);
            scale_row = scale_index/V_LANES;
            if (product_scaled_status[scale_index][O_ACC_W])
                product_saturation_by_row[scale_row] = 1'b1;
        end
    end

    integer add_index;
    integer add_row;
    always @* begin
        add_saturation_by_row = '0;
        for (add_index = 0; add_index < OUT_ELEMS;
             add_index = add_index + 1) begin
            add_status[add_index] = sat_add_status(
                o_acc_reg[add_index],
                scaled_pipe[add_index]);
            if (scaled_alpha_path)
                acc_candidate[add_index] = scaled_pipe[add_index];
            else
                acc_candidate[add_index] =
                    $signed(add_status[add_index][O_ACC_W-1:0]);
            add_row = add_index/V_LANES;
            if (!scaled_alpha_path &&
                add_status[add_index][O_ACC_W])
                add_saturation_by_row[add_row] = 1'b1;
        end
    end

    integer capture_index;
    integer issue_row;
    integer issue_feature;
    integer issue_index;
    integer output_index;
    integer output_row;
    integer error_feature;
    logic signed [COEFF_SIGNED_W-1:0] issue_coeff;
    logic signed [O_ACC_W-1:0] issue_data;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            new_state_valid_reg <= '0;
            old_o_valid_reg <= '0;
            alpha_reg <= '0;
            weights_reg <= '0;
            v_tile_reg <= '0;
            old_o_reg <= '0;
            operand_valid <= 1'b0;
            operand_alpha_path <= 1'b0;
            operand_last <= 1'b0;
            operand_error <= '0;
            product_valid <= 1'b0;
            product_alpha_path <= 1'b0;
            product_last <= 1'b0;
            product_error <= '0;
            scaled_valid <= 1'b0;
            scaled_alpha_path <= 1'b0;
            scaled_last <= 1'b0;
            scaled_error <= '0;
            error_reg <= '0;
            issue_count <= '0;
            out_valid <= 1'b0;
            out_o_valid <= '0;
            out_o_fixed <= '0;
            out_numeric_error <= '0;
            for (capture_index = 0; capture_index < OUT_ELEMS;
                 capture_index = capture_index + 1) begin
                o_acc_reg[capture_index] <= '0;
                operand_data_reg[capture_index] <= '0;
                product_pipe[capture_index] <= '0;
                scaled_pipe[capture_index] <= '0;
            end
            for (issue_row = 0; issue_row < TILE;
                 issue_row = issue_row + 1)
                operand_coeff_reg[issue_row] <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (in_valid && in_ready) begin
                        new_state_valid_reg <= in_new_state_valid;
                        old_o_valid_reg <= in_old_o_valid;
                        alpha_reg <= in_alpha_q23;
                        weights_reg <= in_weights_q23;
                        v_tile_reg <= in_v_tile_bf16;
                        old_o_reg <= in_old_o_fixed;
                        operand_valid <= 1'b0;
                        operand_alpha_path <= 1'b0;
                        operand_last <= 1'b0;
                        operand_error <= '0;
                        product_valid <= 1'b0;
                        product_alpha_path <= 1'b0;
                        product_last <= 1'b0;
                        product_error <= '0;
                        scaled_valid <= 1'b0;
                        scaled_alpha_path <= 1'b0;
                        scaled_last <= 1'b0;
                        scaled_error <= '0;
                        error_reg <= '0;
                        issue_count <= '0;
                        out_o_valid <= '0;
                        out_numeric_error <= '0;
                        for (capture_index = 0;
                             capture_index < OUT_ELEMS;
                             capture_index = capture_index + 1)
                            o_acc_reg[capture_index] <= '0;

                        for (issue_row = 0; issue_row < TILE;
                             issue_row = issue_row + 1) begin
                            if (in_old_o_valid[issue_row] &&
                                !in_new_state_valid[issue_row])
                                error_reg[issue_row] <= 1'b1;
                            for (error_feature = 0;
                                 error_feature < V_LANES;
                                 error_feature = error_feature + 1) begin
                                if (!in_old_o_valid[issue_row] &&
                                    (in_old_o_fixed[
                                        (issue_row*V_LANES +
                                         error_feature)*O_ACC_W +:
                                         O_ACC_W] != '0))
                                    error_reg[issue_row] <= 1'b1;
                            end
                        end
                        state <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    // Register the wide input mux before the DSP array.
                    operand_valid <= 1'b0;
                    if (issue_count < ISSUE_STEPS) begin
                        for (issue_row = 0; issue_row < TILE;
                             issue_row = issue_row + 1) begin
                            if (issue_count == 0)
                                issue_coeff = $signed({1'b0,
                                    alpha_reg[
                                        issue_row*EXP_W +: EXP_W]});
                            else
                                issue_coeff = $signed({1'b0,
                                    weights_reg[
                                        (issue_row*TILE + issue_k)*
                                        EXP_W +: EXP_W]});
                            operand_coeff_reg[issue_row] <= issue_coeff;

                            for (issue_feature = 0;
                                 issue_feature < V_LANES;
                                 issue_feature = issue_feature + 1) begin
                                issue_index =
                                    issue_row*V_LANES + issue_feature;
                                if (issue_count == 0) begin
                                    if (old_o_valid_reg[issue_row])
                                        issue_data = $signed(old_o_reg[
                                            issue_index*O_ACC_W +:
                                            O_ACC_W]);
                                    else
                                        issue_data = '0;
                                end else begin
                                    issue_data = $signed({{
                                        (O_ACC_W-V_FIXED_W){
                                            v_fixed[issue_feature][
                                                V_FIXED_W-1]}},
                                        v_fixed[issue_feature]}) <<<
                                        PV_INPUT_ALIGN;
                                end
                                operand_data_reg[issue_index] <= issue_data;
                            end
                        end
                        operand_valid <= 1'b1;
                        operand_alpha_path <= (issue_count == 0);
                        operand_last <= (issue_count == ISSUE_STEPS-1);
                        operand_error <= '0;
                        if (issue_count != 0) begin
                            for (issue_row = 0; issue_row < TILE;
                                 issue_row = issue_row + 1)
                                if (|v_error)
                                    operand_error[issue_row] <= 1'b1;
                        end
                        issue_count <= issue_count + 1'b1;
                    end

                    // DSP stage. Coefficients and data now start at registers.
                    product_valid <= operand_valid;
                    product_alpha_path <= operand_alpha_path;
                    product_last <= operand_last;
                    product_error <= operand_error;
                    if (operand_valid) begin
                        for (output_index = 0;
                             output_index < OUT_ELEMS;
                             output_index = output_index + 1) begin
                            output_row = output_index/V_LANES;
                            product_pipe[output_index] <=
                                operand_coeff_reg[output_row] *
                                operand_data_reg[output_index];
                        end
                    end

                    // Fixed RNE conversion and product saturation stage.
                    scaled_valid <= product_valid;
                    scaled_alpha_path <= product_alpha_path;
                    scaled_last <= product_last;
                    scaled_error <= product_error |
                                    product_saturation_by_row;
                    if (product_valid) begin
                        for (output_index = 0;
                             output_index < OUT_ELEMS;
                             output_index = output_index + 1)
                            scaled_pipe[output_index] <=
                                product_scaled[output_index];
                    end

                    // Accumulator stage. The last K term creates the response.
                    if (scaled_valid) begin
                        for (output_index = 0;
                             output_index < OUT_ELEMS;
                             output_index = output_index + 1) begin
                            output_row = output_index/V_LANES;
                            o_acc_reg[output_index] <=
                                new_state_valid_reg[output_row] ?
                                    acc_candidate[output_index] : '0;
                        end
                        error_reg <= error_reg | scaled_error |
                                     add_saturation_by_row;

                        if (scaled_last) begin
                            for (output_index = 0;
                                 output_index < OUT_ELEMS;
                                 output_index = output_index + 1) begin
                                output_row = output_index/V_LANES;
                                out_o_fixed[
                                    output_index*O_ACC_W +: O_ACC_W] <=
                                    new_state_valid_reg[output_row] ?
                                        acc_candidate[output_index] : '0;
                            end
                            out_o_valid <= new_state_valid_reg;
                            out_numeric_error <=
                                error_reg | scaled_error |
                                add_saturation_by_row;
                            out_valid <= 1'b1;
                            state <= ST_HOLD;
                        end
                    end
                end

                ST_HOLD: begin
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    out_valid <= 1'b0;
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    initial begin
        if (TILE != 4)
            $error("flash_pv_o_tile_update requires TILE=4");
        if (V_LANES != 8)
            $error("Stage 3A requires V_LANES=8");
        if ((EXP_W != 24) || (EXP_FRAC != 23))
            $error("Stage 3A requires Q1.23 P/alpha");
        if ((V_FIXED_W != 18) || (V_FRAC != 11))
            $error("Stage 3A requires signed Q6.11 V");
        if ((O_ACC_W != 40) || (O_FRAC != 19))
            $error("Stage 3A requires signed 40-bit Q20.19 O");
        if (PV_TO_O_SHIFT <= 0)
            $error("PV_TO_O_SHIFT must be positive");
        if (PV_INPUT_ALIGN < 0)
            $error("PV_INPUT_ALIGN must be non-negative");
    end

endmodule
