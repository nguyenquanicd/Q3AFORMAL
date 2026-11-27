module sva_label_leaf(input logic clk, input logic a);
    property sampled_a;
        @(posedge clk) a;
    endproperty
    check_a: assert property (sampled_a);
    see_a: cover property (sampled_a);
endmodule

module sva_label_wrapper(input logic clk, input logic a);
    sva_label_leaf u_nested(.clk(clk), .a(a));
endmodule

module sva_labeled_checks(input logic clk, input logic a, input logic b);
    sva_label_leaf u_leaf(.clk(clk), .a(a));
    sva_label_wrapper u_wrap(.clk(clk), .a(b));
    constrain_a: assume property (@(posedge clk) a);
    assert_a: assert property (@(posedge clk) a);
    cover_b: cover property (@(posedge clk) b);
endmodule
