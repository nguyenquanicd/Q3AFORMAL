module rtl_unsized_decimal_overflow (input logic clk);
    property p_value; @(posedge clk) 9223372036854775808 > 0; endproperty
    assert property (p_value);
endmodule
