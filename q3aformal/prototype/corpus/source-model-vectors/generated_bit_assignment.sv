module generated_bit_assignment_cell #(
    parameter integer WIDTH = 4
) (
    input  logic [WIDTH-1:0] a,
    output logic [WIDTH-1:0] q
);
    generate
        for (genvar i = 0; i < WIDTH; i = i + 1) begin : g_lane
            assign q[i] = a[WIDTH-1-i];
        end
    endgenerate
endmodule

module generated_bit_assignment_top (
    input  logic clk,
    input  logic [3:0] a_desc,
    input  logic [0:3] a_asc,
    input  logic [3:0] a_part,
    input  logic [0:3] a_part_asc,
    input  logic [3:0] a_genpart,
    input  logic [3:0] child_a,
    output logic [3:0] y_desc,
    output logic [0:3] y_asc,
    output logic [3:0] y_part,
    output logic [0:3] y_part_asc,
    output logic [3:0] y_genpart,
    output logic [3:0] child_y
);
    generated_bit_assignment_cell #(.WIDTH(4)) u_cell (
        .a(child_a),
        .q(child_y)
    );

    assign y_part[3:2] = a_part[3:2];
    assign y_part[1:0] = a_part[1:0];
    assign y_part_asc[0:1] = a_part_asc[0:1];
    assign y_part_asc[2:3] = a_part_asc[2:3];

    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_desc
            assign y_desc[i] = a_desc[3-i];
        end
        for (genvar j = 0; j < 4; j = j + 1) begin : g_asc
            assign y_asc[j] = a_asc[j];
        end
        for (genvar k = 0; k < 4; k = k + 2) begin : g_part
            assign y_genpart[k+1:k] = a_genpart[k+1:k];
        end
    endgenerate

    property p_all_targets_match;
        @(posedge clk)
            (y_desc == {a_desc[0], a_desc[1], a_desc[2], a_desc[3]}) &&
            (y_asc == a_asc) &&
            (y_part == a_part) &&
            (y_part_asc == a_part_asc) &&
            (y_genpart == a_genpart) &&
            (child_y == {child_a[0], child_a[1], child_a[2], child_a[3]});
    endproperty
    property p_desc_not_identity;
        @(posedge clk) y_desc == a_desc;
    endproperty

    assert property (p_all_targets_match);
    assert property (p_desc_not_identity);
endmodule
