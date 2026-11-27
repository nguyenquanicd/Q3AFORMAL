module rtl_concat_three (
    input  logic       clk,
    input  logic [1:0] a,
    input  logic [2:0] b,
    input  logic       c,
    output logic [5:0] y
);
    assign y = {a, b, c};

    property p_three_member_concat_order;
        @(posedge clk)
        (y[5:4] == a) && (y[3:1] == b) && (y[0] == c);
    endproperty

    assert property (p_three_member_concat_order);
endmodule
