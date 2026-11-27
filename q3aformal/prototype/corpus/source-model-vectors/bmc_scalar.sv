module bmc_scalar_top (
    input logic clk,
    input logic a
);
    property p_always_true;
        @(posedge clk) a || !a;
    endproperty

    property p_can_fail;
        @(posedge clk) a;
    endproperty

    assert property (p_always_true);
    assert property (p_can_fail);
endmodule
