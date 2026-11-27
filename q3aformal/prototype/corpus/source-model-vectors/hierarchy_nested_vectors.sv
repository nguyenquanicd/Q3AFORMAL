module hierarchy_nested_leaf (
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic       equal
);
    logic [3:0] xor_value;
    always_comb begin
        xor_value = a ^ b;
        equal = (xor_value == 4'h0);
    end
endmodule

module hierarchy_nested_middle (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_nested_leaf u_compare (
        .a(lhs ^ rhs),
        .b(4'h0),
        .equal(same)
    );
endmodule

module hierarchy_nested_top (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_nested_middle u_middle (
        .lhs(lhs),
        .rhs(rhs),
        .same(same)
    );
endmodule
