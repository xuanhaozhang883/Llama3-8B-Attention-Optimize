`timescale 1ns/1ps

// Throughput-one pipelined exp(-x) approximation for FlashAttention.
//
// The 513-entry base table stores exp(-n/64) in unsigned Q1.23. The remaining
// Q10.14 fraction uses exp(-r) ~= 1-r+r^2/2. Values from 8 to 16 reuse the
// same table multiplied by exp(-8). The pipeline accepts one request per clock
// and returns the matching tag and value after four clocks.
module flash_exp_approx_q23 #(
    parameter integer SCORE_W    = 24,
    parameter integer SCORE_FRAC = 14,
    parameter integer TAG_W      = 3,
    parameter LUT_FILE           = "mem/exp_lut_q23.mem"
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      in_valid,
    input  logic signed [SCORE_W:0]   in_magnitude_fixed,
    input  logic                      in_force_zero,
    input  logic [TAG_W-1:0]          in_tag,

    output logic                      out_valid,
    output logic [23:0]               out_value_q23,
    output logic [TAG_W-1:0]          out_tag
);

    localparam integer COARSE_SHIFT = SCORE_FRAC - 6;
    localparam logic signed [SCORE_W:0] EXP_LIMIT_FIXED =
        16 <<< SCORE_FRAC;
    localparam logic [23:0] EXP_ONE_Q23 = 24'h800000;
    localparam logic [23:0] EXP_NEG8_Q23 = 24'h000afe;

    (* rom_style = "distributed" *) logic [23:0] base_rom [0:512];

    logic [10:0] input_coarse_addr;
    logic [9:0]  input_base_addr;
    logic [COARSE_SHIFT-1:0] input_remainder;
    logic input_is_one;
    logic input_is_zero;

    logic s0_valid;
    logic [TAG_W-1:0] s0_tag;
    logic [23:0] s0_base_raw;
    logic [COARSE_SHIFT-1:0] s0_remainder;
    logic s0_tail_region;
    logic s0_is_one;
    logic s0_is_zero;

    logic s1_valid;
    logic [TAG_W-1:0] s1_tag;
    logic [23:0] s1_base;
    logic [COARSE_SHIFT-1:0] s1_remainder;
    logic [2*COARSE_SHIFT-1:0] s1_remainder_squared;

    logic s2_valid;
    logic [TAG_W-1:0] s2_tag;
    logic [23:0] s2_base;
    logic [24:0] s2_first_order;
    logic [24:0] s2_second_order;

    logic [47:0] tail_product_comb;
    logic [23+COARSE_SHIFT:0] first_product_comb;
    logic [23+2*COARSE_SHIFT:0] second_product_comb;

    initial begin
        if (SCORE_FRAC < 7)
            $error("SCORE_FRAC must be >= 7");
        if (TAG_W < 1)
            $error("TAG_W must be >= 1");
        $readmemh(LUT_FILE, base_rom);
    end

    always_comb begin
        input_coarse_addr = 11'd0;
        input_base_addr = 10'd0;
        input_remainder = '0;
        input_is_one = 1'b0;
        input_is_zero = 1'b0;

        if (in_force_zero || (in_magnitude_fixed > EXP_LIMIT_FIXED)) begin
            input_is_zero = 1'b1;
        end else if (in_magnitude_fixed <= 0) begin
            input_is_one = 1'b1;
        end else begin
            input_coarse_addr =
                $unsigned(in_magnitude_fixed) >> COARSE_SHIFT;
            input_remainder =
                in_magnitude_fixed[COARSE_SHIFT-1:0];
            if (input_coarse_addr <= 11'd512)
                input_base_addr = input_coarse_addr[9:0];
            else
                input_base_addr = input_coarse_addr - 11'd512;
        end
    end

    always_comb begin
        tail_product_comb = s0_base_raw * EXP_NEG8_Q23;
        first_product_comb = s1_base * s1_remainder;
        second_product_comb = s1_base * s1_remainder_squared;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            s0_tag <= '0;
            s0_base_raw <= '0;
            s0_remainder <= '0;
            s0_tail_region <= 1'b0;
            s0_is_one <= 1'b0;
            s0_is_zero <= 1'b0;

            s1_valid <= 1'b0;
            s1_tag <= '0;
            s1_base <= '0;
            s1_remainder <= '0;
            s1_remainder_squared <= '0;

            s2_valid <= 1'b0;
            s2_tag <= '0;
            s2_base <= '0;
            s2_first_order <= '0;
            s2_second_order <= '0;

            out_valid <= 1'b0;
            out_value_q23 <= '0;
            out_tag <= '0;
        end else begin
            s0_valid <= in_valid;
            s0_tag <= in_tag;
            s0_base_raw <= base_rom[input_base_addr];
            s0_remainder <= input_remainder;
            s0_tail_region <= input_coarse_addr > 11'd512;
            s0_is_one <= input_is_one;
            s0_is_zero <= input_is_zero;

            s1_valid <= s0_valid;
            s1_tag <= s0_tag;
            s1_remainder <= s0_remainder;
            s1_remainder_squared <= s0_remainder * s0_remainder;
            if (s0_is_zero)
                s1_base <= 24'd0;
            else if (s0_is_one)
                s1_base <= EXP_ONE_Q23;
            else if (s0_tail_region)
                s1_base <= (tail_product_comb + (1 << 22)) >> 23;
            else
                s1_base <= s0_base_raw;

            s2_valid <= s1_valid;
            s2_tag <= s1_tag;
            s2_base <= s1_base;
            s2_first_order <=
                (first_product_comb + (1 << (SCORE_FRAC-1))) >>
                SCORE_FRAC;
            s2_second_order <=
                (second_product_comb + (1 << (2*SCORE_FRAC))) >>
                (2*SCORE_FRAC + 1);

            out_valid <= s2_valid;
            out_tag <= s2_tag;
            if (s2_first_order >= s2_base)
                out_value_q23 <= 24'd0;
            else
                out_value_q23 <= s2_base - s2_first_order +
                                 s2_second_order;
        end
    end

endmodule
