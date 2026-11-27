module rtl_sized_expression_context (
    input logic clk,
    input logic [7:0] x,
    input logic signed [7:0] s
);
    logic [15:0] wide_sum;
    logic [15:0] nested_sum;
    logic [3:0] narrow_diff;
    logic [15:0] sign_extended;
    logic [15:0] held;
    logic [7:0] temporary_sum;
    logic [15:0] after_temporary_sum;
    logic signed [7:0] temporary_signed;
    logic [15:0] after_temporary_signed;

    assign wide_sum = x + x;
    assign nested_sum = (x + x) + 16'd1;
    assign narrow_diff = x - 8'd1;
    assign sign_extended = s;

    always_comb begin
        temporary_sum = x + x;
        after_temporary_sum = temporary_sum + 16'd1;
        temporary_signed = x;
        after_temporary_signed = temporary_signed + 16'sd1;
    end
    always_ff @(posedge clk) begin
        held <= x + x;
    end

    property p_compare; @(posedge clk)
        ((x+x) == 16'd256) == (x == 8'd128);
    endproperty
    property p_sum; @(posedge clk)
        wide_sum == {7'd0, x, 1'b0} && nested_sum == {7'd0, x, 1'b1};
    endproperty
    property p_diff; @(posedge clk)
        narrow_diff == (x[3:0] - 4'd1);
    endproperty
    property p_sign; @(posedge clk)
        sign_extended == {(s[7] ? 8'hff : 8'h00), s};
    endproperty
    property p_temporary; @(posedge clk)
        after_temporary_sum == {8'd0, x[6:0], 1'b1};
    endproperty
    property p_signed_temporary; @(posedge clk)
        after_temporary_signed == ({(x[7] ? 8'hff : 8'h00), x} + 16'd1);
    endproperty
    property p_state; @(posedge clk)
        1'b1 |=> (held == {7'd0, $past(x), 1'b0});
    endproperty
    property p_lost_carry; @(posedge clk)
        wide_sum == {8'd0, x[6:0], 1'b0};
    endproperty

    assert property(p_compare);
    assert property(p_sum);
    assert property(p_diff);
    assert property(p_sign);
    assert property(p_temporary);
    assert property(p_signed_temporary);
    assert property(p_state);
    assert property(p_lost_carry);
endmodule
