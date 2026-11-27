module sva_sequence_vectors (
    input logic clk,
    input logic a,
    input logic b,
    input logic c
);
    property p_overlapped;
        @(posedge clk) a |-> b;
    endproperty

    property p_nonoverlapped;
        @(posedge clk) a |=> b;
    endproperty

    property p_delay_zero;
        @(posedge clk) (a ##0 b) |-> c;
    endproperty

    property p_delay_one;
        @(posedge clk) a ##1 b;
    endproperty

    property p_delay_two;
        @(posedge clk) a ##2 b;
    endproperty

    property p_repeat_one;
        @(posedge clk) a[*1] |=> b;
    endproperty

    property p_repeat_three;
        @(posedge clk) a[*3] |=> b;
    endproperty

    property p_repeat_bounded;
        @(posedge clk) a[*1:3] ##1 b;
    endproperty

    property p_past_one;
        @(posedge clk) $past(a) |-> b;
    endproperty

    property p_past_two;
        @(posedge clk) $past(a, 2) |-> b;
    endproperty

    assert property (p_overlapped);
    assert property (p_nonoverlapped);
    assert property (p_delay_zero);
    assert property (p_delay_one);
    assert property (p_delay_two);
    assert property (p_repeat_one);
    assert property (p_repeat_three);
    assert property (p_repeat_bounded);
    assert property (p_past_one);
    assert property (p_past_two);

    assume property (@(posedge clk) a || !a);
    cover property (@(posedge clk) a ##1 b);
endmodule

