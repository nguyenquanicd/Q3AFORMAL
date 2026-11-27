module operator_vectors (
    input  logic [3:0] a,
    input  logic [3:0] b,
    input  logic signed [3:0] sa,
    input  logic signed [3:0] sb,
    output logic [3:0] add_y,
    output logic [3:0] sub_y,
    output logic [3:0] unary_minus_y,
    output logic [3:0] bit_not_y,
    output logic       logical_not_y,
    output logic [3:0] and_y,
    output logic [3:0] or_y,
    output logic [3:0] xor_y,
    output logic [3:0] xnor_y,
    output logic       logical_and_y,
    output logic       logical_or_y,
    output logic       eq_y,
    output logic       ne_y,
    output logic       unsigned_lt_y,
    output logic       signed_lt_y,
    output logic [3:0] mux_y,
    output logic [7:0] concat_y,
    output logic       bit_select_y,
    output logic [3:0] part_select_y,
    output logic [3:0] left_shift_y,
    output logic [3:0] right_shift_y
);
    assign add_y = a + b;
    assign sub_y = a - b;
    assign unary_minus_y = -a;
    assign bit_not_y = ~a;
    assign logical_not_y = !a;
    assign and_y = a & b;
    assign or_y = a | b;
    assign xor_y = a ^ b;
    assign xnor_y = a ~^ b;
    assign logical_and_y = (a != 4'h0) && (b != 4'h0);
    assign logical_or_y = (a != 4'h0) || (b != 4'h0);
    assign eq_y = (a == b);
    assign ne_y = (a != b);
    assign unsigned_lt_y = (a < b);
    assign signed_lt_y = (sa < sb);
    assign mux_y = a[0] ? a : b;
    assign concat_y = {a, b};
    assign bit_select_y = a[3];
    assign part_select_y = concat_y[7:4];
    assign left_shift_y = a << 1;
    assign right_shift_y = a >> 1;
endmodule
