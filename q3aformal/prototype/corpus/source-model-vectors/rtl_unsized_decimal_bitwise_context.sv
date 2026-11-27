module rtl_unsized_decimal_bitwise_context (
    input logic clk,
    input logic [7:0] x,
    input logic signed [7:0] s
);
    logic [7:0] masked;
    logic [15:0] sum_bits;
    logic [31:0] unsigned_complement;
    logic [39:0] signed_complement;
    logic [31:0] inverse_xor;
    logic [31:0] inverse_xor_alternate;
    logic [7:0] comb_mask;
    logic [15:0] state_sum_bits;
    logic [31:0] zero_extended_s;
    logic signed [39:0] sign_extended_s;
    logic [15:0] extended_x;
    logic [39:0] shifted;
    logic [39:0] conditional_wide;
    logic [7:0] large_shift_count;
    logic [39:0] signed_right_shift;
    localparam logic signed [31:0] MAX_SIGNED_32 = 32'sh7fffffff;
    logic [39:0] narrow_predicate;
    logic [39:0] wide_comparison;
    logic [39:0] self_sized_shift_count;
    logic [39:0] self_sized_member;

    assign masked = x & 1;
    assign sum_bits = (x + x) & 511;
    assign unsigned_complement = ~(s + 1) | 32'h00000000;
    assign signed_complement = ~(s + 1);
    assign inverse_xor = x ~^ 1;
    assign inverse_xor_alternate = x ^~ 1;
    always_comb begin
        comb_mask = x ^ 7;
    end
    always_ff @(posedge clk) begin
        state_sum_bits <= (x + x) & 511;
    end

    assign extended_x = {8'h00, x};
    assign zero_extended_s = {24'h000000, s};
    assign sign_extended_s = {(s[7] ? 32'hffffffff : 32'h00000000), s};
    assign shifted = 1 << 39;
    assign conditional_wide = x[0] ? -1 : (1 << 39);
    assign large_shift_count = x >> 4294967296;
    assign signed_right_shift = (-1) >> 1;
    assign narrow_predicate = ((MAX_SIGNED_32 + 1) < 0) ? 40'd1 : 40'd2;
    assign wide_comparison = ((MAX_SIGNED_32 + 1) < 40'sd0) ? 40'd1 : 40'd2;
    assign self_sized_shift_count = 40'd1 << (((MAX_SIGNED_32 + 1) < 0) ? 8'd3 : 8'd4);
    assign self_sized_member = {7'd0, (MAX_SIGNED_32 + 1), x[0]};

    property p_mask; @(posedge clk)
        masked == {7'b0000000, x[0]};
    endproperty
    property p_sum_bits; @(posedge clk)
        sum_bits == {7'b0000000, x, 1'b0};
    endproperty
    property p_unsigned_complement; @(posedge clk)
        unsigned_complement == ~(zero_extended_s + 32'h00000001);
    endproperty
    property p_signed_complement; @(posedge clk)
        signed_complement == ~(sign_extended_s + 40'sh0000000001);
    endproperty
    property p_inverse_xor; @(posedge clk)
        inverse_xor == {24'hffffff, ~x[7:1], x[0]};
    endproperty
    property p_inverse_xor_alternate; @(posedge clk)
        inverse_xor_alternate == inverse_xor;
    endproperty
    property p_comb_mask; @(posedge clk)
        comb_mask == {x[7:3], ~x[2:0]};
    endproperty
    property p_state_bits; @(posedge clk)
        1'b1 |=> state_sum_bits == $past(extended_x << 1);
    endproperty
    property p_comparison; @(posedge clk)
        (((x + x) | 8'h00) == 256) == (x == 8'h80);
    endproperty
    property p_carry_lost; @(posedge clk)
        sum_bits == {8'h00, x[6:0], 1'b0};
    endproperty
    property p_decimal_shift_context; @(posedge clk)
        (shifted == 40'h8000000000) &&
        (large_shift_count == 8'h00) &&
        (signed_right_shift == 40'h7fffffffff);
    endproperty
    property p_decimal_conditional_context; @(posedge clk)
        conditional_wide == (x[0] ? 40'hffffffffff : 40'h8000000000);
    endproperty
    property p_self_determined_context; @(posedge clk)
        (narrow_predicate == 40'd1) && (wide_comparison == 40'd2) &&
        (self_sized_shift_count == 40'd8) &&
        (self_sized_member == {39'h0080000000, x[0]});
    endproperty
    property p_wrong_predicate_context; @(posedge clk)
        narrow_predicate == 40'd2;
    endproperty

    assert property (p_mask);
    assert property (p_sum_bits);
    assert property (p_unsigned_complement);
    assert property (p_signed_complement);
    assert property (p_inverse_xor);
    assert property (p_inverse_xor_alternate);
    assert property (p_comb_mask);
    assert property (p_state_bits);
    assert property (p_comparison);
    assert property (p_carry_lost);
    assert property (p_decimal_shift_context);
    assert property (p_decimal_conditional_context);
    assert property (p_self_determined_context);
    assert property (p_wrong_predicate_context);
endmodule
