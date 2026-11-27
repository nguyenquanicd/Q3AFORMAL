module rtl_unsized_decimal_context (
    input  logic        clk,
    output logic [7:0]   u8_one,
    output logic [7:0]   u8_truncate,
    output logic signed [7:0] s8_negative,
    output logic [39:0]  u40_one,
    output logic signed [39:0] s40_negative,
    output logic [7:0]   u8_sum,
    output logic [7:0]   comb_value,
    output logic [7:0]   state_value
);
    assign u8_one       = 1;
    assign u8_truncate  = 257;
    assign s8_negative = -2;
    assign u40_one      = 1;
    assign s40_negative = -2;
    assign u8_sum       = 1 + 2;

    always_comb begin
        comb_value = 3;
    end

    always_ff @(posedge clk) begin
        state_value <= -4;
    end

    property p_unsized_decimal_assignment_context;
        @(posedge clk)
        (u8_one == 8'd1) &&
        (u8_truncate == 8'd1) &&
        (s8_negative == -8'sd2) &&
        (u40_one == 40'd1) &&
        (s40_negative == -40'sd2) &&
        (u8_sum == 8'd3) &&
        (comb_value == 8'd3);
    endproperty

    assert property (p_unsized_decimal_assignment_context);
endmodule
