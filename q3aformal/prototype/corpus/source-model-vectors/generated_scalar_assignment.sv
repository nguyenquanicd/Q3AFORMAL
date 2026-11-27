module generated_assignment_cell #(
    parameter integer BASE = 5
) (
    input  logic [31:0] a,
    output logic [31:0] q
);
    generate
        for (genvar j = BASE; j < BASE + 1; j = j + 1) begin : g_child
            assign q = a ^ j;
        end
    endgenerate
endmodule

module generated_assignment_top #(
    parameter integer ENABLE = 1,
    parameter integer BASE = 2
) (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y,
    output logic [31:0] child_y
);
    generated_assignment_cell #(.BASE(5)) u_child (
        .a(a),
        .q(child_y)
    );
    generate
        if (ENABLE) begin : g_enabled
            for (genvar i = BASE; i < BASE + 1; i = i + 1) begin : g_item
                assign y = a ^ i;
            end
        end else begin : g_disabled
            assign y = unresolved_inactive_signal;
        end
    endgenerate
endmodule