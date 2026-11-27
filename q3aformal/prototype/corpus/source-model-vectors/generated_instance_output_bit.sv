module generated_instance_output_lane (
    input  logic source_bit,
    output logic output_bit
);
    assign output_bit = source_bit;
endmodule

module generated_instance_output_bit_top (
    input  logic clk,
    input  logic [3:0] a,
    output logic [3:0] y
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            generated_instance_output_lane u_lane (
                .source_bit(a[i]),
                .output_bit(y[i])
            );
        end
    endgenerate

    property p_output_map;
        @(posedge clk) y == a;
    endproperty
    property p_output_wrong;
        @(posedge clk) y != a;
    endproperty
    assert property (p_output_map);
    assert property (p_output_wrong);
endmodule

module generated_instance_output_bit_ascending_top (
    input  logic clk,
    input  logic [0:3] a,
    output logic [0:3] y
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            generated_instance_output_lane u_lane (
                .source_bit(a[i]),
                .output_bit(y[i])
            );
        end
    endgenerate

    property p_output_map_ascending;
        @(posedge clk) y == a;
    endproperty
    assert property (p_output_map_ascending);
endmodule

module generated_instance_output_bit_partial (
    input  logic [3:0] a,
    output logic [3:0] y
);
    generate
        for (genvar i = 0; i < 3; i = i + 1) begin : g_lane
            generated_instance_output_lane u_lane (
                .source_bit(a[i]),
                .output_bit(y[i])
            );
        end
    endgenerate
endmodule

module generated_instance_output_bit_duplicate (
    input  logic [3:0] a,
    output logic [3:0] y
);
    generated_instance_output_lane u_first (
        .source_bit(a[0]),
        .output_bit(y[0])
    );
    generated_instance_output_lane u_second (
        .source_bit(a[1]),
        .output_bit(y[0])
    );
    generated_instance_output_lane u_third (
        .source_bit(a[1]),
        .output_bit(y[1])
    );
    generated_instance_output_lane u_fourth (
        .source_bit(a[2]),
        .output_bit(y[2])
    );
    generated_instance_output_lane u_fifth (
        .source_bit(a[3]),
        .output_bit(y[3])
    );
endmodule

module generated_instance_output_bit_whole_conflict (
    input  logic [3:0] a,
    output logic [3:0] y
);
    assign y = a;
    generated_instance_output_lane u_lane (
        .source_bit(a[0]),
        .output_bit(y[0])
    );
endmodule

module generated_instance_output_bit_dynamic (
    input  logic [3:0] a,
    input  logic [1:0] index,
    output logic [3:0] y
);
    generated_instance_output_lane u_lane (
        .source_bit(a[0]),
        .output_bit(y[index])
    );
endmodule

module generated_instance_output_bit_out_of_range (
    input  logic [3:0] a,
    output logic [3:0] y
);
    generated_instance_output_lane u_lane (
        .source_bit(a[0]),
        .output_bit(y[4])
    );
endmodule

module generated_instance_output_part_select (
    input  logic [3:0] a,
    output logic [3:0] y
);
    generated_instance_output_lane u_lane (
        .source_bit(a[0]),
        .output_bit(y[3:2])
    );
endmodule
