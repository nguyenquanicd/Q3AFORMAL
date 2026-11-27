module rtl_inferred_parameters #(
    localparam HEADER_BASE = 3'd4,
    parameter WIDTH = HEADER_BASE,
    parameter SIGNED_SEED = 3'sb111
) (input logic clk, input logic [WIDTH-1:0] data);
    localparam MODULAR = 3'd7 + 3'd2;
    localparam NEGATIVE = SIGNED_SEED;
    localparam WIDER = 2147483648;
    parameter BODY_ALIAS = MODULAR + 3'd2;
    localparam logic [63:0] HIGH_U64 = 64'h8000_0000_0000_0000;
    localparam MAX_U64 = {32'hffff_ffff, 32'hffff_ffff};
    localparam PACKED_BITS = {3'sb111, {1'b0, '1}};
    localparam logic [7:0] PACKED_EXTENDED = {3'sb111, {1'b0, '1}};
    localparam PACKED_SUM = {(3'd7 + 3'd1), 1'b1};
    localparam logic signed [63:0] NEGATIVE_WIDE = MAX_U64;
    localparam logic signed [63:0] MIN_SIGNED_WIDE = HIGH_U64;
    localparam WRAP_U64 = MAX_U64 + 64'd1;
    logic [63:0] wide_value;
    inferred_wide_child #(.VALUE(MAX_U64)) u_wide(.value(wide_value));
    logic [WIDTH-1:0] overridden;
    logic [3:0] positional_value;
    logic [2:0] default_value;
    logic [1:0] required_value;
    inferred_parameter_child u_default(.data(3'b111), .value(default_value));
    inferred_parameter_child #(.LANES(WIDTH)) u_override(.data(data), .value(overridden));
    inferred_parameter_child #(3'd3, 3'd4) u_body_positional(
        .data(data), .value(positional_value));
    inferred_required_child #(2'b11) u_required(.value(required_value));

    property p_expected; @(posedge clk)
        MODULAR == 3'd1 && WIDER == 33'd2147483648 && BODY_ALIAS == 3'd3 &&
        PACKED_BITS == 5'd29 && PACKED_EXTENDED == 8'd29 && PACKED_SUM == 4'd1 &&
        (NEGATIVE < 4'sd0) && !(NEGATIVE < 4'd2) &&
        default_value == 3'd7 && overridden == data && positional_value == data &&
        required_value == 2'd3;
    endproperty
    property p_wrong; @(posedge clk)
        MODULAR == 4'd9;
    endproperty
    property p_unsigned64; @(posedge clk)
        HIGH_U64 > 64'h7fff_ffff_ffff_ffff && MAX_U64 > HIGH_U64 &&
        MIN_SIGNED_WIDE < NEGATIVE_WIDE && NEGATIVE_WIDE < 64'sd0 &&
        MIN_SIGNED_WIDE == HIGH_U64 && NEGATIVE_WIDE == MAX_U64 &&
        WRAP_U64 == 64'd0 && wide_value == 64'hffff_ffff_ffff_ffff;
    endproperty
    property p_wrong_unsigned64; @(posedge clk)
        wide_value == 64'h7fff_ffff_ffff_ffff;
    endproperty
    assert property (p_expected);
    assert property (p_wrong);
    assert property (p_unsigned64);
    assert property (p_wrong_unsigned64);
endmodule

module inferred_wide_child #(
    parameter VALUE = 64'd0
) (output logic [63:0] value);
    assign value = VALUE;
endmodule

module inferred_parameter_child (
    input logic [LIMIT-1:0] data, output logic [LIMIT-1:0] value
);
    parameter LANES = 3'd3;
    localparam BASE = LANES;
    parameter LIMIT = BASE;
    assign value = data;
endmodule

module inferred_required_child #(
    localparam REQUIRED_WIDTH = 3'd2,
    parameter MASK
) (output logic [REQUIRED_WIDTH-1:0] value);
    assign value = MASK;
endmodule
