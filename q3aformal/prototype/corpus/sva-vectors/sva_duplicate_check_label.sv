module sva_duplicate_check_label(input logic clk, input logic a);
    check_a: assert property (@(posedge clk) a);
    check_a: cover property (@(posedge clk) a);
endmodule
