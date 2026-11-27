module sva_compound_exact_repeat(input logic clk, input logic start, input logic a, input logic b);
    c_prefixed: cover property (@(posedge clk)
        start ##2 (a ##2 b)[*2:2]);
    p_guarded: assert property (@(posedge clk)
        (a ##0 b)[*2] |-> $past(a));
    p_wrong: assert property (@(posedge clk)
        (a ##0 b)[*2] |-> !$past(a));
    p_nested: assert property (@(posedge clk)
        ((1'b1 ##0 1'b1)[*2])[*2]);
    c_ranged: cover property (@(posedge clk)
        start ##1 (a ##1 b)[*1:3] ##1 start);
    c_nested_ranged: cover property (@(posedge clk)
        ((a ##0 b)[*1:2])[*2]);
    p_range_guarded: assert property (@(posedge clk)
        (a ##0 b)[*2:3] |-> $past(a));
    p_range_wrong: assert property (@(posedge clk)
        (a ##0 b)[*2:3] |-> !$past(a));
    p_range_consequent: assert property (@(posedge clk)
        1'b1 |-> (1'b1 ##0 1'b1)[*1:3]);
endmodule
