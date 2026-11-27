module sva_compound_repeat_limit(input logic clk, input logic a, input logic b);
    large_repeat: cover property (@(posedge clk) (a ##0 b)[*5001]);
endmodule
