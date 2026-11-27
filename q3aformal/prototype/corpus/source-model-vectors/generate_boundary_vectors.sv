module generate_count_vectors #(
    parameter integer COUNT = 0
) (
    output logic is_one
);
    assign is_one = (COUNT == 1);

    generate
        for (genvar i = 0; i < COUNT; i = i + 1) begin : g_items
            localparam integer ITEM_INDEX = i;
        end
    endgenerate
endmodule

module nested_generate_vectors #(
    parameter integer WIDTH = 4,
    parameter integer ENABLE = 1
) (
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    output logic [WIDTH-1:0] y
);
    generate
        if (ENABLE != 0) begin : g_enabled
            if (WIDTH == 4) begin : g_width_four
                assign y = a ^ b;
            end else begin : g_other_width
                assign y = a & b;
            end
        end else begin : g_disabled
            assign y = '0;
        end
    endgenerate
endmodule
