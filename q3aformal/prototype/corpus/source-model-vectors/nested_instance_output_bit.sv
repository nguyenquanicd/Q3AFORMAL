module nested_output_bit_leaf (
    input  logic d,
    output logic q
);
    assign q = d;
endmodule

module nested_output_bit_wrapper (
    input  logic d,
    output logic q
);
    logic q_local;

    nested_output_bit_leaf u_leaf (
        .d(d),
        .q(q_local)
    );
    assign q = q_local;
endmodule

module nested_instance_output_bit_top (
    input  logic clk,
    input  logic [3:0] a,
    output logic [3:0] y
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            nested_output_bit_wrapper u_wrapper (
                .d(a[i]),
                .q(y[i])
            );
        end
    endgenerate

    property p_nested_output_map;
        @(posedge clk) y == a;
    endproperty
    assert property (p_nested_output_map);
endmodule
