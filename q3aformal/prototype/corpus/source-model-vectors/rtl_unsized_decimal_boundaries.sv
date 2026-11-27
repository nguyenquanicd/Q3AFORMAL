module decimal_boundary_port (
    input logic [32:0] d,
    output logic [32:0] q
);
    assign q = d;
endmodule

module rtl_unsized_decimal_boundaries (
    input logic clk,
    output logic [32:0] from_port,
    output logic [7:0] truncated,
    output logic [39:0] widened
);
    decimal_boundary_port child (.d(2_147_483_648), .q(from_port));
    assign truncated = 4_294_967_297;
    assign widened = 2_147_483_648;

    property p_min_width; @(posedge clk) 2147483647 > 0; endproperty
    property p_extra_sign_bit; @(posedge clk) 2147483648 > 0; endproperty
    property p_magnitude_bit; @(posedge clk) 4294967296 > 4294967295; endproperty
    property p_max_positive; @(posedge clk) 9_223_372_036_854_775_807 > 0; endproperty
    property p_unary_minus; @(posedge clk) -2147483648 < 0; endproperty
    property p_port; @(posedge clk) from_port == 33'd2147483648; endproperty
    property p_truncate; @(posedge clk) truncated == 8'd1; endproperty
    property p_widen; @(posedge clk) widened == 40'd2147483648; endproperty
    property p_deliberately_false; @(posedge clk) 2147483648 < 0; endproperty

    assert property (p_min_width);
    assert property (p_extra_sign_bit);
    assert property (p_magnitude_bit);
    assert property (p_max_positive);
    assert property (p_unary_minus);
    assert property (p_port);
    assert property (p_truncate);
    assert property (p_widen);
    assert property (p_deliberately_false);
endmodule
