module bit_passthrough (
    input  logic d,
    output logic q
);
    assign q = d;
endmodule

module generated_hierarchy_top #(
    parameter integer WIDTH = 4,
    parameter integer ENABLE = 1
) (
    input  logic [WIDTH-1:0] data_in,
    input  logic             flag_in,
    output logic [WIDTH-1:0] data_out,
    output logic             flag_out
);
    generate
        if (ENABLE) begin : g_enabled
            bit_passthrough u_flag (
                .d(flag_in),
                .q(flag_out)
            );
        end else begin : g_disabled
            missing_generated_module u_inactive (
                .d(flag_in),
                .q(flag_out)
            );
        end

        for (genvar i = 0; i < WIDTH; i = i + 1) begin : g_bits
            bit_passthrough u_bit (
                .d(data_in[i]),
                .q(data_out[i])
            );
        end
    endgenerate
endmodule
