module bmc_sequence_assumption_top (
    input logic clk,
    input logic a,
    input logic b,
    input logic c,
    input logic d
);
    property p_overlapped;
        @(posedge clk) (a ##1 b) |-> (c ##2 d);
    endproperty

    assume property (p_overlapped);
    assert property (p_overlapped);
endmodule
