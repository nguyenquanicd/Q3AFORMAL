module rtl_shift_assignment_context (
    input logic clk,
    input logic sel,
    input logic [7:0] x,
    input logic signed [7:0] s
);
    logic [15:0] left_wide;
    logic [15:0] right_wide;
    logic [15:0] signed_right;
    logic [7:0] narrow;
    logic [39:0] isolated_distance;
    logic [15:0] next_left;
    logic [15:0] added_shift;
    logic [15:0] selected_shift;
    logic [15:0] mixed_shift;
    logic [15:0] selected_sum_wide;
    logic [7:0] selected_sum_narrow;
    logic [39:0] condition_isolated;

    assign left_wide = x << 1;
    assign right_wide = (x + x) >> 1;
    assign signed_right = s >> 1;
    assign narrow = 16'h0200 >> 2;
    assign isolated_distance = 40'd1 << (2147483647 + 1 + 2147483647 + 1);
    assign added_shift = (x << 1) + 16'd1;
    assign selected_shift = sel ? (x << 1) : 16'h0003;
    assign mixed_shift = sel ? (s >> 1) : 16'h0003;
    always_comb begin
        selected_sum_wide = sel ? (x + x) : 8'd3;
        selected_sum_narrow = sel ? (x + 16'h00ff) : 16'd3;
    end
    assign condition_isolated = (2147483647 + 1 + 2147483647 + 1) ? 40'd1 : 40'd2;
    always_ff @(posedge clk) begin
        next_left <= x << 1;
    end

    property p_left; @(posedge clk)
        left_wide == {7'd0, x, 1'b0};
    endproperty
    property p_right; @(posedge clk)
        right_wide == {8'd0, x};
    endproperty
    property p_signed; @(posedge clk)
        signed_right == {1'b0, (s[7] ? 8'hff : 8'h00), s[7:1]};
    endproperty
    property p_truncate; @(posedge clk)
        narrow == 8'h80;
    endproperty
    property p_distance; @(posedge clk)
        isolated_distance == 40'd1;
    endproperty
    property p_state; @(posedge clk)
        1'b1 |=> next_left == {7'd0, $past(x), 1'b0};
    endproperty
    property p_lost_bit; @(posedge clk)
        left_wide == {8'd0, x[6:0], 1'b0};
    endproperty
    property p_nested_compare; @(posedge clk)
        ((x << 1) == 16'd256) == (x == 8'd128);
    endproperty
    property p_nested_add; @(posedge clk)
        added_shift == {7'd0, x, 1'b1};
    endproperty
    property p_nested_select; @(posedge clk)
        sel |-> selected_shift == {7'd0, x, 1'b0};
    endproperty
    property p_nested_mixed; @(posedge clk)
        sel |-> mixed_shift == {9'd0, s[7:1]};
    endproperty
    property p_alternate_branch; @(posedge clk)
        !sel |-> (mixed_shift == 16'd3 && selected_shift == 16'd3 &&
                  selected_sum_wide == 16'd3 && selected_sum_narrow == 8'd3);
    endproperty
    property p_condition_isolated; @(posedge clk)
        condition_isolated == 40'd2;
    endproperty
    property p_selected_sum_wide; @(posedge clk)
        sel |-> selected_sum_wide == {7'd0, x, 1'b0};
    endproperty
    property p_selected_sum_narrow; @(posedge clk)
        sel |-> selected_sum_narrow == (x - 8'd1);
    endproperty

    assert property (p_left);
    assert property (p_right);
    assert property (p_signed);
    assert property (p_truncate);
    assert property (p_distance);
    assert property (p_state);
    assert property (p_lost_bit);
    assert property (p_nested_compare);
    assert property (p_nested_add);
    assert property (p_nested_select);
    assert property (p_nested_mixed);
    assert property (p_alternate_branch);
    assert property (p_condition_isolated);
    assert property (p_selected_sum_wide);
    assert property (p_selected_sum_narrow);
endmodule
