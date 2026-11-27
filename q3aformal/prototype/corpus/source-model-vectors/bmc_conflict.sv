module bmc_conflict_top (
    input logic clk,
    input logic a
);
    property p_assume_a;
        @(posedge clk) a;
    endproperty

    property p_assume_not_a;
        @(posedge clk) !a;
    endproperty

    property p_assert_a;
        @(posedge clk) a;
    endproperty

    property p_cover_a;
        @(posedge clk) a |=> a;
    endproperty

    assume property (p_assume_a);
    assume property (p_assume_not_a);
    assert property (p_assert_a);
    cover property (p_cover_a);
endmodule
