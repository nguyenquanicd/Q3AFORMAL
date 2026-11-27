module rtl_unsized_decimal_nested_context (
    input logic clk,
    input logic [7:0] x,
    input logic signed [7:0] s,
    output logic [15:0] unsigned_sum,
    output logic [15:0] signed_sum,
    output logic [15:0] mixed_sum,
    output logic [15:0] negated,
    output logic signed [15:0] based_sum,
    output logic [15:0] registered_sum,
    output logic [15:0] shifted
);
    assign unsigned_sum = (x + x) + 1;
    assign signed_sum = (s + s) + 1;
    assign mixed_sum = (s + s) + (x + 1);
    assign negated = -x + 1;
    assign shifted = 16'd1 << ((4'sd7 + 4'sd1) + 0);
    always_comb begin
        based_sum = (s + 8'sd1) + 1;
    end
    always_ff @(posedge clk) begin
        registered_sum <= (x + x) + 1;
    end

    property p_all_unsigned; @(posedge clk)
        unsigned_sum == (({24'd0, x} + {24'd0, x}) + 32'd1);
    endproperty
    property p_unsigned_carry; @(posedge clk)
        (x == 8'd255) |-> (unsigned_sum == 16'd511);
    endproperty
    property p_signed_carry; @(posedge clk)
        (s == 8'sh80) |-> (signed_sum == 16'hff01);
    endproperty
    property p_mixed_zero_extension; @(posedge clk)
        ((s == 8'shff) && (x == 8'd1)) |-> (mixed_sum == 16'd512);
    endproperty
    property p_widen_before_negating; @(posedge clk)
        (x == 8'd255) |-> (negated == 16'hff02);
    endproperty
    property p_sized_literal_context; @(posedge clk)
        (s == 8'sd127) |-> (based_sum == 16'sd129);
    endproperty
    property p_comparison_context; @(posedge clk)
        (s == 8'shff) |-> (((s + s) + 1) == 40'd511);
    endproperty
    property p_state_carry; @(posedge clk)
        (x == 8'd255) |=> (registered_sum == 16'd511);
    endproperty
    property p_decimal_on_other_side; @(posedge clk)
        (x == 8'd255) |-> ((x + x) == 510);
    endproperty
    property p_shift_context; @(posedge clk) shifted == 16'd256; endproperty
    property p_false_shift; @(posedge clk) shifted == 16'd128; endproperty
    property p_deliberately_false; @(posedge clk)
        (x == 8'd255) |-> (unsigned_sum == 16'd255);
    endproperty

    assert property (p_all_unsigned);
    assert property (p_unsigned_carry);
    assert property (p_signed_carry);
    assert property (p_mixed_zero_extension);
    assert property (p_widen_before_negating);
    assert property (p_sized_literal_context);
    assert property (p_comparison_context);
    assert property (p_state_carry);
    assert property (p_decimal_on_other_side);
    assert property (p_shift_context);
    assert property (p_false_shift);
    assert property (p_deliberately_false);
endmodule
