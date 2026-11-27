module generated_bit_assignment_partial (
    input  logic [3:0] a,
    output logic [3:0] y
);
    generate
        for (genvar i = 0; i < 3; i = i + 1) begin : g_partial
            assign y[i] = a[i];
        end
    endgenerate
endmodule

module generated_bit_assignment_duplicate (
    input  logic [3:0] a,
    output logic [3:0] y
);
    assign y[2] = a[2];
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_duplicate
            assign y[i] = a[i];
        end
    endgenerate
endmodule

module generated_bit_assignment_whole_conflict (
    input  logic [3:0] a,
    output logic [3:0] y
);
    assign y = a;
    assign y[0] = a[0];
endmodule

module generated_bit_assignment_dynamic (
    input  logic [3:0] a,
    input  logic [1:0] index,
    output logic [3:0] y
);
    assign y[index] = a[0];
endmodule

module generated_bit_assignment_out_of_range (
    input  logic [3:0] a,
    output logic [3:0] y
);
    assign y[4] = a[0];
endmodule

module generated_bit_assignment_part_select (
    input  logic [3:0] a,
    output logic [3:0] y
);
    assign y[0:2] = a[3:1];
endmodule
