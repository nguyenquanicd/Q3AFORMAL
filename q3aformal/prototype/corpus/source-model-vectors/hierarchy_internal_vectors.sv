module hierarchy_internal_leaf (
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic       equal
);
    logic [3:0] xor_value;
    assign xor_value = a ^ b;
    assign equal = (xor_value == 4'h0);
endmodule

module hierarchy_internal_top (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_internal_leaf u_compare (
        .a(lhs),
        .b(rhs),
        .equal(same)
    );
endmodule
