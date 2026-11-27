module pdr_temporal_assumptions(input logic clk, input logic a, input logic b);
    env_next: assume property (@(posedge clk) a |=> b);
    p_local: assert property (@(posedge clk) !$past(a, 1) || b);
    p_too_strong: assert property (@(posedge clk) $past(a, 1) == b);
    c_excluded: cover property (@(posedge clk) $past(a, 1) && !b);
    c_allowed: cover property (@(posedge clk) $past(a, 1) && b);
endmodule

module pdr_temporal_contradiction(input logic clk, input logic a);
    env_first: assume property (@(posedge clk) 1'b1 |=> a);
    env_second: assume property (@(posedge clk) 1'b1 |=> !a);
    p_false: assert property (@(posedge clk) 1'b0);
    p_true: assert property (@(posedge clk) 1'b1);
endmodule

module pdr_excessive_assumption(input logic clk, input logic a);
    env_excessive: assume property (@(posedge clk) a |-> a ##129 a);
    p_true: assert property (@(posedge clk) 1'b1);
endmodule
