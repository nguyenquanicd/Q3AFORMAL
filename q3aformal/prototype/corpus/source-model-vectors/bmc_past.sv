module bmc_past_top (
    input logic clk,
    input logic a
);
    property p_past_a;
        @(posedge clk) $past(a);
    endproperty

    property p_past_tautology;
        @(posedge clk) $past(a) || !$past(a);
    endproperty

    assert property (p_past_a);
    assert property (p_past_tautology);
endmodule
