module generated_invert_cell #(
    parameter integer INVERT = 0
) (
    input  logic d,
    output logic q
);
    logic inverted;
    assign inverted = INVERT ? ~d : d;
    assign q = inverted;
endmodule

module generated_scalar_top #(
    parameter integer ENABLE = 1,
    parameter integer LIMIT = 2
) (
    input  logic a,
    output logic y
);
    generate
        if (ENABLE) begin : g_enabled
            for (genvar i = 1; i < LIMIT; i = i + 1) begin : g_item
                generated_invert_cell #(.INVERT(i == 1)) u (
                    .d(a),
                    .q(y)
                );
            end
        end else begin : g_disabled
            missing_generated_cell u_missing (.d(a), .q(y));
        end
    endgenerate
endmodule
