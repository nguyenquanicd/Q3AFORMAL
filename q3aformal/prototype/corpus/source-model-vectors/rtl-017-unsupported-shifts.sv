module rtl_017_unsupported_shifts (
    input logic clk,
    input logic [3:0] a,
    input logic [2:0] amount
);
    property p_dynamic_shift;
        @(posedge clk) (a << amount) == 4'b0000;
    endproperty

    property p_negative_shift;
        @(posedge clk) (a >> -4'sd1) == 4'b0000;
    endproperty

    assert property (p_dynamic_shift);
    assert property (p_negative_shift);
endmodule
