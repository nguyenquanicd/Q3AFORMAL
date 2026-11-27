module multiclock_reject_bench (
    input logic clk_a,
    input logic clk_b,
    input logic req,
    input logic ack
);
    assert property (@(posedge clk_a) req |-> @(posedge clk_b) ack);
endmodule
