module rtl_elaboration_sized_bounds #(
    parameter logic [2:0] HIGH = 3'd7,
    parameter logic [3'd7 + 3'd3 : 3'd0] WINDOW = '1
) (input logic clk, input logic [7:0] x, input logic [HIGH + 3'd3 : 3'd0] lane);
    localparam logic signed [2:0] SIGNED_MINUS_ONE = -3'sd1;
    localparam logic signed [2:0] SIGNED_ONE = 3'sd1;
    localparam logic [~3'b101 : 3'd0] LOCAL_MASK = '1;
    logic [3'd0 : ~3'b101] small;
    assign small = lane;
    logic [2:0] child_value;
    logic [2:0] signed_value;
    logic [2:0] parameter_value;
    logic [2:0] localparam_value;
    logic [2:0] bitwise_value;
    logic [2:0] concatenated_value;
    logic [2:0] conditional_value;
    logic [2:0] generated_value;
    logic [2:0] decimal_generated_value;
    logic [5:0] scoped_value;
    localparam MASK = 3'd0;
    select_width_child u_child(.data(x[3'd7 + 3'd3 : 3'd0]), .value(child_value));
    select_width_child u_signed(
        .data(x[(3'sd3 + 3'sd3) + 4'sd1 : 4'sd5]), .value(signed_value));
    select_width_child u_parameter(
        .data(x[HIGH + 3'd3 : 3'd0]), .value(parameter_value));
    select_width_child u_localparam(
        .data(x[SIGNED_MINUS_ONE + 4'd0 : 4'd5]), .value(localparam_value));
    select_width_child u_bitwise(
        .data(x[~(HIGH ^ HIGH) ^ 3'd5 : 3'd0]), .value(bitwise_value));
    select_width_child u_concatenated(
        .data(x[{1'b1, 1'b0} : {1'b0}]), .value(concatenated_value));
    select_width_child u_conditional(
        .data(x[((SIGNED_MINUS_ONE < 4'd8) && !(3'd7 + 3'd1))
            ? (3'd2 << (3'd7 + 3'd1)) : SIGNED_ONE : 3'd0]),
        .value(conditional_value));
    generate
        if (SIGNED_MINUS_ONE < 4'd2) begin : g_wrong
            localparam UNUSED = MISSING_IF_ACTIVE;
            select_width_child u_generated(.data(x[5:3]), .value(generated_value));
        end else begin : g_expected
            select_width_child u_generated(.data(x[2:0]), .value(generated_value));
        end
        for (genvar j = 0; j < 2; j = j + 1) begin : g_scope
            localparam MASK = (j == 0) ? 3'd1 : 3'd2;
            parameter CHILD_LAST = MASK | 3'd7;
            if (MASK != 3'd0) begin : g_active
                select_width_child #(.LAST(CHILD_LAST)) u_scoped(
                    .data(x[2:0] ^ MASK), .value(scoped_value[j+j+j+2 : j+j+j]));
            end
        end
        if (2147483647 + 1 < 0) begin : g_decimal
            select_width_child u_generated(.data(x[2:0]), .value(decimal_generated_value));
        end else begin : g_decimal_wrong
            select_width_child u_generated(.data(x[5:3]), .value(decimal_generated_value));
        end
    endgenerate

    property p_expected; @(posedge clk)
        child_value == x[2:0] && signed_value == x[7:5] &&
        parameter_value == x[2:0] && localparam_value == x[7:5] &&
        bitwise_value == x[2:0] && concatenated_value == x[2:0] &&
        conditional_value == x[2:0] && generated_value == x[2:0] &&
        decimal_generated_value == x[2:0] &&
        scoped_value[2:0] == (x[2:0] ^ 3'd1) &&
        scoped_value[5:3] == (x[2:0] ^ 3'd2) && MASK == 3'd0 &&
        small[0:2] == lane[2:0] && WINDOW == 3'd7 && LOCAL_MASK == 3'd7;
    endproperty
    property p_wrong; @(posedge clk)
        child_value == x[5:3];
    endproperty
    property p_wrong_scope; @(posedge clk)
        scoped_value[5:3] == (x[2:0] ^ 3'd1);
    endproperty
    assert property (p_expected);
    assert property (p_wrong);
    assert property (p_wrong_scope);
endmodule

module select_width_child #(
    parameter logic [2:0] LAST = 3'd7,
    parameter logic [LAST + 3'd3 : 3'd0] WINDOW = '1
) (
    input logic [LAST + 3'd3 : 3'd0] data,
    output logic [LAST + 3'd3 : 3'd0] value
);
    localparam logic [~3'b101 : 3'd0] LOCAL_MASK = '1;
    generate
        for (genvar i = ((3'd7 + 3'd1) == 3'd0) ? 0 : 1;
             i < 1 && !(3'd7 + 3'd1);
             i = i + (((3'd7 + 3'd1) == 3'd0) ? 1 : 0)) begin : g_lane
            localparam UPPER = (i == 0) ? (LAST + 3'd3) : 3'd0;
            localparam logic [UPPER:0] ACTIVE_MASK = '1;
            logic [UPPER : i] inner;
            assign inner = data & WINDOW;
            assign value = inner & LOCAL_MASK & ACTIVE_MASK;
        end
    endgenerate
endmodule
