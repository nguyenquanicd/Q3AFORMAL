module sva_alignment_vectors (
    input logic clk,
    input logic a,
    input logic b,
    input logic c,
    input logic d
);
    property p_overlapped_chain;
        @(posedge clk) (a ##1 b) |-> (c ##2 d);
    endproperty

    property p_nonoverlapped_chain;
        @(posedge clk) (a ##1 b) |=> (c ##2 d);
    endproperty

    property p_zero_delay_chain;
        @(posedge clk) (a ##0 b) |-> c;
    endproperty

    property p_bounded_repeat;
        @(posedge clk) a[*1:3] |=> b;
    endproperty

    property p_exact_repeat_one;
        @(posedge clk) a[*1] |=> b;
    endproperty

    property p_exact_repeat_two;
        @(posedge clk) a[*2] |=> b;
    endproperty

    property p_exact_repeat_three;
        @(posedge clk) a[*3] |=> b;
    endproperty

    property p_equal_bounds_repeat;
        @(posedge clk) a[*2:2] |=> b;
    endproperty

    assert property (p_overlapped_chain);
    assert property (p_nonoverlapped_chain);
    assert property (p_zero_delay_chain);
    assert property (p_bounded_repeat);
    assert property (p_exact_repeat_one);
    assert property (p_exact_repeat_two);
    assert property (p_exact_repeat_three);
    assert property (p_equal_bounds_repeat);
endmodule
