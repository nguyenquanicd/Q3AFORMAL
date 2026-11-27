module pdr_activation(input logic clk, input logic a, input logic b);
    logic q1;
    logic q2;

    always_ff @(posedge clk) begin
        q1 <= a;
        q2 <= q1;
    end

    env_response: assume property (@(posedge clk) a |=> b);
    p_unreachable: assert property (@(posedge clk) a ##[1:2] (!q1 && !q2) |=> b);
    p_excluded: assert property (@(posedge clk) a ##1 !b |-> b);
    p_active: assert property (@(posedge clk) a ##1 b |=> a ##[1:2] b);
    p_guarded: assert property (@(posedge clk) a |=> $past(a, 2));
    p_standalone: assert property (@(posedge clk) 1'b1 ##1 $past(a, 2));
    c_hit: cover property (@(posedge clk) b);
endmodule
