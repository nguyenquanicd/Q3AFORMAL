module bmc_assumption_top (
    input logic clk,
    input logic a
);
    property p_environment_a;
        @(posedge clk) a;
    endproperty

    property p_assert_a;
        @(posedge clk) a;
    endproperty

    assume property (p_environment_a);
    assert property (p_assert_a);
endmodule
