module sva_assumption_consistent (
    input logic clk,
    input logic a
);
    property p_assume_a;
        @(posedge clk) a;
    endproperty
    property p_assert_a;
        @(posedge clk) a;
    endproperty
    assume property (p_assume_a);
    assert property (p_assert_a);
endmodule

module sva_assumption_contradictory (
    input logic clk,
    input logic a
);
    property p_assume_a_high;
        @(posedge clk) a;
    endproperty
    property p_assume_a_low;
        @(posedge clk) !a;
    endproperty
    property p_assert_a_high;
        @(posedge clk) a;
    endproperty
    assume property (p_assume_a_high);
    assume property (p_assume_a_low);
    assert property (p_assert_a_high);
endmodule
