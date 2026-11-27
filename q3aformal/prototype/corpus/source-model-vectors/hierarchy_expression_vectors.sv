module hierarchy_expression_leaf (
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic       equal
);
    assign equal = (a == b);
endmodule

module hierarchy_expression_top (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_expression_leaf u_compare (
        .a(lhs ^ rhs),
        .b(rhs),
        .equal(same)
    );
endmodule
