module rtl_parameter_initializer_types #(
    parameter logic [7:0] TOP_VALUE = 3'sb111 + 4'd0
) (input logic clk);
    localparam logic signed [2:0] SEED = -3'sd1;
    localparam logic [7:0] LOCAL_VALUE = (SEED + 4'd0) + 4'd1;
    localparam logic [7:0] SIGNED_VALUE = SEED + 3'sd0;
    localparam logic [7:0] FILL_VALUE = '1;
    localparam logic [7:0] OR_ADD_VALUE = (SEED | 4'd0) + 4'd1;
    localparam logic [7:0] MASKED_XOR = (SEED ^ 4'd8) & '1;
    localparam logic [7:0] COMPLEMENT = ~(SEED ^ 4'd0);
    localparam logic [7:0] XNOR_LEFT = SEED ~^ 4'd0;
    localparam logic [7:0] XNOR_RIGHT = 3'd7 ^~ 4'd0;
    localparam logic [7:0] SIGNED_COMPLEMENT = ~SEED;
    localparam logic signed [63:0] WIDE_MASK = 64'hffff_ffff_ffff_fff0 | 4'd3;
    localparam logic [7:0] CHECK_UNSIGNED = (SEED < 4'd8) ? SEED : 4'd0;
    localparam logic [7:0] CHECK_SIGNED = (SEED < 4'sd1) ? SEED : 4'sd0;
    localparam logic [7:0] CHECK_BOOLEAN_WIDTH = (3'd7 + 3'd1 == 3'd0) + 8'd5;
    localparam logic [7:0] CHECK_LOGIC_WIDTH = !(3'd7 + 3'd1) + 8'd5;
    localparam logic [7:0] CHECK_SHIFT = (3'd1 << (3'd7 + 3'd1)) | 8'd8;
    localparam logic [7:0] CHECK_SHIFT_SIGN = (SEED >> 3'd1) + 4'd0;
    localparam logic [7:0] CHECK_SHIFT_WIDE = (8'd1 << 7'd64) | (8'hff >> 7'd64);
    localparam logic [7:0] CHECK_FILL_CONDITION = '1 ? '1 : 8'd0;
    logic [7:0] defaults;
    logic [7:0] overridden;
    parameter_initializer_child u_default(.value(defaults));
    parameter_initializer_child #(.CHILD((SEED | 4'd0) + 4'd2)) u_override(.value(overridden));

    property p_expected; @(posedge clk)
        TOP_VALUE == 8'd7 && LOCAL_VALUE == 8'd8 && SIGNED_VALUE == 8'hff &&
        FILL_VALUE == 8'hff && defaults == 8'd7 && overridden == 8'd9;
    endproperty
    property p_override_expected; @(posedge clk)
        TOP_VALUE == 8'd6 && LOCAL_VALUE == 8'd8 && overridden == 8'd9;
    endproperty
    property p_wrong; @(posedge clk)
        TOP_VALUE == 8'hff;
    endproperty
    property p_bitwise; @(posedge clk)
        OR_ADD_VALUE == 8'd8 && MASKED_XOR == 8'd15 && COMPLEMENT == 8'hf8 &&
        XNOR_LEFT == 8'hf8 && XNOR_RIGHT == 8'hf8 && SIGNED_COMPLEMENT == 8'd0 &&
        WIDE_MASK == 64'hffff_ffff_ffff_fff3;
    endproperty
    property p_context; @(posedge clk)
        CHECK_UNSIGNED == 8'd7 && CHECK_SIGNED == 8'hff &&
        CHECK_BOOLEAN_WIDTH == 8'd6 && CHECK_LOGIC_WIDTH == 8'd6 &&
        CHECK_SHIFT == 8'd9 && CHECK_SHIFT_SIGN == 8'd3 && CHECK_SHIFT_WIDE == 8'd0 &&
        CHECK_FILL_CONDITION == 8'hff;
    endproperty
    property p_wrong_context; @(posedge clk)
        CHECK_SHIFT == 8'd8;
    endproperty
    assert property(p_expected);
    assert property(p_override_expected);
    assert property(p_wrong);
    assert property(p_bitwise);
    assert property(p_context);
    assert property(p_wrong_context);
endmodule

module parameter_initializer_child #(
    parameter logic [7:0] CHILD = 3'sb111 + 4'd0
) (output logic [7:0] value);
    assign value = CHILD;
endmodule
