module generate_vectors #(
    parameter integer WIDTH = 4
) (
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    output logic [WIDTH-1:0] y
);
    generate
        if (WIDTH == 4) begin : g_width_four
            assign y[0] = a[0] ^ b[0];
        end else begin : g_other_width
            assign y[0] = a[0] & b[0];
        end

        for (genvar i = 1; i < WIDTH; i = i + 1) begin : g_bits
            assign y[i] = a[i] ^ b[i];
        end
    endgenerate
endmodule
