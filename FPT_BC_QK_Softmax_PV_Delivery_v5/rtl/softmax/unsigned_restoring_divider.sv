`timescale 1ns/1ps

module unsigned_restoring_divider #(
    parameter int NUM_W = 46,
    parameter int DEN_W = 22
) (
    input  logic                 clk,
    input  logic                 rst_n,       // synchronous, active low
    input  logic                 start,
    input  logic [NUM_W-1:0]     numerator,
    input  logic [DEN_W-1:0]     denominator,
    output logic                 busy,
    output logic                 done,
    output logic                 divide_by_zero,
    output logic [NUM_W-1:0]     quotient,
    output logic [DEN_W-1:0]     remainder
);

    localparam int COUNT_W = (NUM_W <= 2) ? 1 : $clog2(NUM_W + 1);

    logic [NUM_W-1:0] dividend_shift;
    logic [NUM_W-1:0] quotient_work;
    logic [DEN_W:0]   remainder_work;
    logic [DEN_W-1:0] denominator_reg;
    logic [COUNT_W-1:0] count;

    logic [DEN_W:0] remainder_shifted;
    logic [DEN_W:0] remainder_after_sub;
    logic           quotient_bit;

    always_comb begin
        remainder_shifted = {remainder_work[DEN_W-1:0], dividend_shift[NUM_W-1]};
        if (remainder_shifted >= {1'b0, denominator_reg}) begin
            remainder_after_sub = remainder_shifted - {1'b0, denominator_reg};
            quotient_bit = 1'b1;
        end else begin
            remainder_after_sub = remainder_shifted;
            quotient_bit = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy             <= 1'b0;
            done             <= 1'b0;
            divide_by_zero   <= 1'b0;
            quotient         <= '0;
            remainder        <= '0;
            dividend_shift   <= '0;
            quotient_work    <= '0;
            remainder_work   <= '0;
            denominator_reg  <= '0;
            count            <= '0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                divide_by_zero <= (denominator == '0);
                if (denominator == '0) begin
                    quotient <= {NUM_W{1'b1}};
                    remainder <= '0;
                    done      <= 1'b1;
                    busy      <= 1'b0;
                end else begin
                    busy            <= 1'b1;
                    dividend_shift  <= numerator;
                    quotient_work   <= '0;
                    remainder_work  <= '0;
                    denominator_reg <= denominator;
                    count           <= '0;
                end
            end else if (busy) begin
                dividend_shift <= {dividend_shift[NUM_W-2:0], 1'b0};
                quotient_work  <= {quotient_work[NUM_W-2:0], quotient_bit};
                remainder_work <= remainder_after_sub;

                if (count == NUM_W-1) begin
                    quotient  <= {quotient_work[NUM_W-2:0], quotient_bit};
                    remainder <= remainder_after_sub[DEN_W-1:0];
                    busy      <= 1'b0;
                    done      <= 1'b1;
                end else begin
                    count <= count + 1'b1;
                end
            end
        end
    end

endmodule
