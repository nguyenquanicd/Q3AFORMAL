module sva_nested_past (
    input logic clk,
    input logic a,
    input logic b
);
    property p_nested_past;
        @(posedge clk) $past($past(a)) |-> b;
    endproperty

    assert property (p_nested_past);
endmodule
