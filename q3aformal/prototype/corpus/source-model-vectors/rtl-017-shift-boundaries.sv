module rtl_017_shift_boundaries (
    input logic clk,
    input logic [3:0] a
);
    property p_left_0; @(posedge clk) (a << 0) == a; endproperty
    property p_left_1; @(posedge clk) (a << 1) == {a[2:0], 1'b0}; endproperty
    property p_left_2; @(posedge clk) (a << 2) == {a[1:0], 2'b00}; endproperty
    property p_left_3; @(posedge clk) (a << 3) == {a[0], 3'b000}; endproperty
    property p_left_4; @(posedge clk) (a << 4) == 4'b0000; endproperty
    property p_left_5; @(posedge clk) (a << 5) == 4'b0000; endproperty
    property p_left_6; @(posedge clk) (a << 6) == 4'b0000; endproperty
    property p_left_7; @(posedge clk) (a << 7) == 4'b0000; endproperty

    property p_right_0; @(posedge clk) (a >> 0) == a; endproperty
    property p_right_1; @(posedge clk) (a >> 1) == {1'b0, a[3:1]}; endproperty
    property p_right_2; @(posedge clk) (a >> 2) == {2'b00, a[3:2]}; endproperty
    property p_right_3; @(posedge clk) (a >> 3) == {3'b000, a[3]}; endproperty
    property p_right_4; @(posedge clk) (a >> 4) == 4'b0000; endproperty
    property p_right_5; @(posedge clk) (a >> 5) == 4'b0000; endproperty
    property p_right_6; @(posedge clk) (a >> 6) == 4'b0000; endproperty
    property p_right_7; @(posedge clk) (a >> 7) == 4'b0000; endproperty

    assert property (p_left_0);
    assert property (p_left_1);
    assert property (p_left_2);
    assert property (p_left_3);
    assert property (p_left_4);
    assert property (p_left_5);
    assert property (p_left_6);
    assert property (p_left_7);
    assert property (p_right_0);
    assert property (p_right_1);
    assert property (p_right_2);
    assert property (p_right_3);
    assert property (p_right_4);
    assert property (p_right_5);
    assert property (p_right_6);
    assert property (p_right_7);
endmodule
