module pdr_range_sequence(input logic clk, input logic a, input logic b);
    logic q1;
    logic q2;
    always_ff @(posedge clk) begin
        q1 <= a;
        q2 <= q1;
    end

    p_either_endpoint: assert property (@(posedge clk) a |-> 1'b1 ##[1:2] q1);
    p_late_endpoint: assert property (@(posedge clk) a |-> 1'b1 ##[1:2] q2);
    p_repeated_antecedent: assert property (@(posedge clk) a[*1:2] |=> q1);
    p_no_consequent_match: assert property (@(posedge clk) a |-> 1'b1 ##[1:2] !q1);
    p_late_trigger: assert property (@(posedge clk) a ##[1:2] b |-> q1);
    p_overlapping_matches: assert property (@(posedge clk) a[*2:3] ##1 b[*1:2] |-> q1);
    p_standalone_range: assert property (@(posedge clk) 1'b1 ##[1:2] b);
    p_end_guard: assert property (@(posedge clk) a |=> $past(a, 2) ##[1:2] b);
    c_short_hit: cover property (@(posedge clk) a ##[2:3] q2);
    c_repeated_hit: cover property (@(posedge clk) a[*2:3] |=> q1);
    c_unreachable_range: cover property (@(posedge clk) a[*1:2] |=> !q1);
endmodule
