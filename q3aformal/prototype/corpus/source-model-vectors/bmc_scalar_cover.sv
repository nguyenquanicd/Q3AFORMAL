module bmc_scalar_cover_top (
    input logic clk,
    input logic hit
);
    cover property (@(posedge clk) hit);
endmodule
