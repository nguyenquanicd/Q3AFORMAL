module rtl_literal_expression_vectors (
    input  logic [3:0]       u,
    input  logic [3:0]       v,
    input  logic [1:0]       small,
    input  logic signed [3:0] s,
    input  logic signed [3:0] t,
    input  logic             cond,
    output bit [3:0]         bit_type_copy,
    output logic [7:0]       unsized_positive,
    output logic signed [7:0] unsized_negative,
    output logic [7:0]       based_binary,
    output logic [7:0]       based_octal,
    output logic [7:0]       based_decimal,
    output logic [7:0]       based_hex,
    output logic signed [7:0] based_signed_negative,
    output logic [3:0]       fill_zero,
    output logic [3:0]       fill_one,
    output logic [7:0]       fill_zero_wide,
    output logic [7:0]       fill_one_wide,
    output logic [3:0]       unary_plus,
    output logic [3:0]       unary_minus,
    output logic [3:0]       bitwise_not,
    output logic             logical_not,
    output logic [3:0]       add_wrap,
    output logic [3:0]       subtract_wrap,
    output logic [3:0]       bitwise_and,
    output logic [3:0]       bitwise_or,
    output logic [3:0]       bitwise_xor,
    output logic [3:0]       bitwise_xnor,
    output logic [3:0]       bitwise_and_mixed_width,
    output logic             logical_and,
    output logic             logical_or,
    output logic             eq,
    output logic             ne,
    output logic             unsigned_lt,
    output logic             unsigned_le,
    output logic             unsigned_gt,
    output logic             unsigned_ge,
    output logic             signed_lt,
    output logic             signed_le,
    output logic             signed_gt,
    output logic             signed_ge,
    output logic signed [7:0] signed_conditional,
    output logic [7:0]       concatenation,
    output logic [5:0]       mixed_width_concatenation,
    output logic [3:0]       descending_select,
    output logic [3:0]       ascending_select,
    output logic [3:0]       shift_left_0,
    output logic [3:0]       shift_left_3,
    output logic [3:0]       shift_left_4,
    output logic [3:0]       shift_left_5,
    output logic [3:0]       shift_right_0,
    output logic [3:0]       shift_right_3,
    output logic [3:0]       shift_right_4,
    output logic [3:0]       shift_right_5
);
    logic [7:0] descending;
    logic [0:7] ascending;

    assign bit_type_copy        = u;
    assign unsized_positive      = 1;
    assign unsized_negative      = -1;
    assign based_binary          = 8'b1010_0110;
    assign based_octal           = 8'o246;
    assign based_decimal         = 8'd166;
    assign based_hex             = 8'hA6;
    assign based_signed_negative = -8'sd2;
    assign fill_zero             = '0;
    assign fill_one              = '1;
    assign fill_zero_wide       = '0;
    assign fill_one_wide        = '1;

    assign unary_plus      = +u;
    assign unary_minus     = -u;
    assign bitwise_not     = ~u;
    assign logical_not     = !u;
    assign add_wrap        = u + 4'h1;
    assign subtract_wrap   = u - 4'h1;
    assign bitwise_and     = u & v;
    assign bitwise_or      = u | v;
    assign bitwise_xor     = u ^ v;
    assign bitwise_xnor    = u ~^ v;
    assign bitwise_and_mixed_width = u & small;
    assign logical_and     = (u != 4'h0) && (v != 4'h0);
    assign logical_or      = (u != 4'h0) || (v != 4'h0);

    assign eq              = (u == v);
    assign ne              = (u != v);
    assign unsigned_lt     = (u < v);
    assign unsigned_le     = (u <= v);
    assign unsigned_gt     = (u > v);
    assign unsigned_ge     = (u >= v);
    assign signed_lt       = (s < t);
    assign signed_le       = (s <= t);
    assign signed_gt       = (s > t);
    assign signed_ge       = (s >= t);

    assign signed_conditional = cond ? s : 8'sd5;
    assign concatenation      = {u, v};
    assign mixed_width_concatenation = {u, small};

    assign descending = 8'h96;
    assign ascending  = 8'b1001_0110;
    assign descending_select = descending[6:3];
    assign ascending_select  = ascending[0:3];

    assign shift_left_0  = u << 0;
    assign shift_left_3  = u << 3;
    assign shift_left_4  = u << 4;
    assign shift_left_5  = u << 5;
    assign shift_right_0 = u >> 0;
    assign shift_right_3 = u >> 3;
    assign shift_right_4 = u >> 4;
    assign shift_right_5 = u >> 5;
endmodule



