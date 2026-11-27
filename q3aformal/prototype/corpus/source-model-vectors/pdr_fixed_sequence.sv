module pdr_fixed_sequence(
    input logic clk,
    input logic a,
    input logic b,
    input logic __q3a_pdr_monitor_0
);
    logic q1;
    logic q2;
    logic q3;

    always_ff @(posedge clk) begin
        q1 <= a;
        q2 <= q1;
        q3 <= q2;
    end

    p_pipeline: assert property (@(posedge clk) a ##1 b |=> q2);
    p_wrong_pipeline: assert property (@(posedge clk) a ##1 b |=> !q2);
    p_repeat: assert property (@(posedge clk) a[*2] |-> q1);
    p_consequent_delay: assert property (@(posedge clk) a |-> a ##2 q2);
    p_guarded_pipeline: assert property (@(posedge clk) $past(a, 1) ##1 b |=> q3);
    p_wrong_guarded: assert property (@(posedge clk) $past(a, 1) ##1 b |=> !q3);
    p_consequent_guard: assert property (@(posedge clk) a |=> $past(a, 2) ##1 b);
    p_standalone: assert property (@(posedge clk) 1'b1 ##2 (q2 == $past(a, 2)));
    p_standalone_fail: assert property (@(posedge clk) 1'b1 ##2 __q3a_pdr_monitor_0);
    c_reachable: cover property (@(posedge clk) a[*2] ##1 q2);
    c_unreachable: cover property (@(posedge clk) a[*2] ##1 !q2);
    c_guarded_hit: cover property (@(posedge clk) a |=> $past(a, 2));
    c_unreachable_implication: cover property (@(posedge clk) a ##1 b |=> !q2);
    p_delay_range: assert property (@(posedge clk) a ##[1:2] b |=> q2);
    p_repetition_range: assert property (@(posedge clk) a[*1:2] |-> a);
    p_excessive_horizon: assert property (@(posedge clk) a |-> a ##129 b);
endmodule
