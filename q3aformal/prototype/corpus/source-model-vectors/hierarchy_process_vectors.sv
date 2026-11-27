module hierarchy_process_leaf (
    input  logic [3:0] a,
    input  logic [3:0] b,
    output logic       equal
);
    always_comb begin
        if (a == b) begin
            equal = 1'b1;
        end else begin
            equal = 1'b0;
        end
    end
endmodule

module hierarchy_process_top (
    input  logic [3:0] lhs,
    input  logic [3:0] rhs,
    output logic       same
);
    hierarchy_process_leaf u_compare (
        .a(lhs),
        .b(rhs),
        .equal(same)
    );
endmodule
