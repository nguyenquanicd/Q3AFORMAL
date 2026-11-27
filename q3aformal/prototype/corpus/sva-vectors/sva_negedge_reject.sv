module sva_negedge_reject (
    input logic clk,
    input logic a
);
    property p_negedge;
        @(negedge clk) a;
    endproperty
    assert property (p_negedge);
endmodule
