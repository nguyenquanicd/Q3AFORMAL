module rtl_fill_literal_widths (
    input  logic        clk,
    output logic [1:0]  zero_2,
    output logic [1:0]  one_2,
    output logic [4:0]  zero_5,
    output logic [4:0]  one_5,
    output logic [12:0] zero_13,
    output logic [12:0] one_13
);
    assign zero_2  = '0;
    assign one_2   = '1;
    assign zero_5  = '0;
    assign one_5   = '1;
    assign zero_13 = '0;
    assign one_13  = '1;

    property p_fill_context_width;
        @(posedge clk)
        (zero_2 == 2'b00) && (one_2 == 2'b11) &&
        (zero_5 == 5'b00000) && (one_5 == 5'b11111) &&
        (zero_13 == 13'b0) && (one_13 == 13'b1_1111_1111_1111);
    endproperty

    assert property (p_fill_context_width);
endmodule
