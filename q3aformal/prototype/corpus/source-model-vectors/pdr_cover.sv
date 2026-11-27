module pdr_cover_example(input logic clk, input logic a);
    logic q1;
    logic q2;

    always_ff @(posedge clk) begin
        q1 <= a;
        q2 <= q1;
    end

    p_never: cover property (@(posedge clk) q2 != $past(a, 2));
    p_hit: cover property (@(posedge clk) q2 == $past(a, 2));
    p_immediate: cover property (@(posedge clk) a |-> a);
    p_no_vacuity: cover property (@(posedge clk) a |-> !a);
    p_same_sample: cover property (@(posedge clk) a ##0 !a);
    p_delayed: cover property (@(posedge clk) a ##1 a);
endmodule
