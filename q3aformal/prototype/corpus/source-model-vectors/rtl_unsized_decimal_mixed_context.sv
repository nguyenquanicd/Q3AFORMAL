module rtl_unsized_decimal_mixed_context (
    input  logic              clk,
    input  logic              reset_n,
    input  logic        [7:0] u8_input,
    input  logic signed [7:0] s8_input,
    input  logic       [39:0] u40_input,
    output logic        [7:0] u8_plus_one,
    output logic        [7:0] u8_minus_one,
    output logic        [7:0] u8_negated_plus_one,
    output logic signed [7:0] s8_plus_one,
    output logic signed [7:0] s8_minus_one,
    output logic       [15:0] u16_plus_one,
    output logic       [39:0] u40_plus_one,
    output logic        [7:0] comb_plus_one,
    output logic        [7:0] state_plus_one
);
    assign u8_plus_one  = u8_input + 1;
    assign u8_minus_one = u8_input - 1;
    assign u8_negated_plus_one = -(u8_input + 1);
    assign s8_plus_one  = s8_input + 1;
    assign s8_minus_one = s8_input - 1;
    assign u16_plus_one = u8_input + 1;
    assign u40_plus_one = u40_input + 1;

    always_comb begin
        comb_plus_one = u8_input + 1;
    end

    always_ff @(posedge clk) begin
        if (!reset_n)
            state_plus_one <= 8'd0;
        else
            state_plus_one <= s8_input + 1;
    end

    property p_mixed_decimal_assignment_context;
        @(posedge clk)
        (u8_plus_one == u8_input + 8'd1) &&
        (u8_minus_one == u8_input - 8'd1) &&
        (u8_negated_plus_one == -(u8_input + 8'd1)) &&
        (s8_plus_one == s8_input + 8'sd1) &&
        (s8_minus_one == s8_input - 8'sd1) &&
        (u16_plus_one == {8'd0, u8_input} + 16'd1) &&
        (u40_plus_one == u40_input + 40'd1) &&
        (comb_plus_one == u8_input + 8'd1);
    endproperty

    assert property (p_mixed_decimal_assignment_context);

    property p_mixed_decimal_counterexample;
        @(posedge clk)
        u8_plus_one == u8_input + 8'd2;
    endproperty

    assert property (p_mixed_decimal_counterexample);
endmodule
