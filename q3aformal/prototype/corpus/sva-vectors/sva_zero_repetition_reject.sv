module sva_zero_repetition_reject (
    input logic clk,
    input logic a,
    input logic b
);
    property p_exact_zero;
        @(posedge clk) a[*0] |-> b;
    endproperty

    property p_zero_minimum;
        @(posedge clk) a[*0:2];
    endproperty

    assert property (p_exact_zero);
    cover property (p_zero_minimum);
endmodule
