module pdr_example(input logic clk, input logic a);
    logic q1;
    logic q2;
    always_ff @(posedge clk) begin
        q1 <= a;
        q2 <= q1;
    end
    p_safe: assert property (@(posedge clk) q2 == $past(a, 2));
    p_bad: assert property (@(posedge clk) q2 != $past(a, 2));
    p_temporal: assert property (@(posedge clk) a |=> a);
endmodule
