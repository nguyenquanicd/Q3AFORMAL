module unlisted_sva_reject_bench (
    input logic clk,
    input logic req
);
    assert property (@(posedge clk) $rose(req));
endmodule
