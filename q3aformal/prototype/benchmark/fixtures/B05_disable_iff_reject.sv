module disable_iff_reject_bench (
    input logic clk,
    input logic rst,
    input logic req
);
    assert property (@(posedge clk) disable iff (!rst) req);
endmodule
