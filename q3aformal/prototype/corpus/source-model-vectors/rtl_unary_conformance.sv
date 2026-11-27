module rtl_unary_conformance (
    input  logic       clk,
    input  logic [3:0] u,
    output logic [3:0] unary_plus,
    output logic [3:0] unary_minus,
    output logic [3:0] bitwise_not,
    output logic       logical_not
);
    assign unary_plus = +u;
    assign unary_minus = -u;
    assign bitwise_not = ~u;
    assign logical_not = !u;

    property p_unary_plus;
        @(posedge clk) unary_plus == u;
    endproperty
    assert property (p_unary_plus);

    property p_unary_minus;
        @(posedge clk) unary_minus == (~u + 4'd1);
    endproperty
    assert property (p_unary_minus);

    property p_bitwise_not;
        @(posedge clk) bitwise_not == (4'hf ^ u);
    endproperty
    assert property (p_bitwise_not);

    property p_logical_not;
        @(posedge clk) logical_not == (u == 4'h0);
    endproperty
    assert property (p_logical_not);

    property p_unary_plus_false;
        @(posedge clk) unary_plus != u;
    endproperty
    assert property (p_unary_plus_false);
endmodule
