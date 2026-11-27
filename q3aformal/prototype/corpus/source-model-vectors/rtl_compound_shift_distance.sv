module rtl_compound_shift_distance(input logic clk, input logic [7:0] x);
    logic [7:0] signed_distance;
    logic [7:0] unsigned_distance;
    logic [7:0] logical_distance;
    logic [7:0] xnor_distance;

    assign signed_distance = x << ((-3'sd2 < 5'sd1) ? 3'd2 : 3'd7);
    assign unsigned_distance = x >> ((-3'sd2 > 5'd1) ? 3'd3 : 3'd7);
    assign logical_distance = x << (((3'd4 != 5'd1) && !1'b0) ? 3'd1 : 3'd7);
    assign xnor_distance = x >> (3'b100 ~^ 3'b001);

    property p_fixed_distances; @(posedge clk)
        signed_distance == {x[5:0], 2'b00} &&
        unsigned_distance == {3'b000, x[7:3]} &&
        logical_distance == {x[6:0], 1'b0} &&
        xnor_distance == {2'b00, x[7:2]};
    endproperty
    property p_wrong_distance; @(posedge clk)
        signed_distance == {x[6:0], 1'b0};
    endproperty
    property p_dynamic_distance; @(posedge clk)
        (x << (1'b1 ? 3'd1 : x[2:0])) == 8'd0;
    endproperty
    property p_negative_distance; @(posedge clk)
        (x << (1'b1 ? -3'sd1 : 3'sd1)) == 8'd0;
    endproperty
    assert property (p_fixed_distances);
    assert property (p_wrong_distance);
    assert property (p_dynamic_distance);
    assert property (p_negative_distance);
endmodule
