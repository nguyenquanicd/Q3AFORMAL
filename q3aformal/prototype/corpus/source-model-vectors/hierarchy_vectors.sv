module hierarchy_leaf (
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic       equal
);
    assign equal = (a == b);
endmodule

module hierarchy_top (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_leaf u_compare (
        .a(lhs),
        .b(rhs),
        .equal(same)
    );
endmodule

module hierarchy_positional_top (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_leaf u_compare (lhs, rhs, same);
endmodule
