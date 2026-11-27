module child_property_leaf (
    input  logic clk,
    input  logic d,
    output logic q
);
    assign q = d;

    property p_copy;
        @(posedge clk) q == d;
    endproperty
    assert property (p_copy);

    property p_not_copy;
        @(posedge clk) q != d;
    endproperty
    assert property (p_not_copy);

    property p_copy_history;
        @(posedge clk) $past(q) == $past(d);
    endproperty
    assert property (p_copy_history);

    assert property (@(posedge clk) q == d);

    property p_assume_data_low;
        @(posedge clk) d == 1'b0;
    endproperty
    assume property (p_assume_data_low);

    cover property (@(posedge clk) d == 1'b1);
endmodule

module child_module_property_top (
    input  logic clk,
    input  logic a,
    output logic y
);
    child_property_leaf u_leaf (
        .clk(clk),
        .d(a),
        .q(y)
    );
endmodule

module nested_child_property_wrapper (
    input  logic clk,
    input  logic d,
    output logic q
);
    child_property_leaf u_leaf (
        .clk(clk),
        .d(d),
        .q(q)
    );
endmodule

module nested_child_property_top (
    input  logic clk,
    input  logic a,
    output logic y
);
    nested_child_property_wrapper u_wrapper (
        .clk(clk),
        .d(a),
        .q(y)
    );
endmodule

module deep_nested_property_wrapper (
    input  logic clk,
    input  logic d,
    output logic q
);
    nested_child_property_wrapper u_inner (
        .clk(clk),
        .d(d),
        .q(q)
    );
endmodule

module generated_child_property_bit_top (
    input  logic clk,
    input  logic [3:0] a,
    output logic [3:0] y
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            child_property_leaf u_leaf (
                .clk(clk),
                .d(a[i]),
                .q(y[i])
            );
        end
    endgenerate
endmodule

module generated_nested_child_property_bit_top (
    input  logic clk,
    input  logic [3:0] a,
    output logic [3:0] y
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            deep_nested_property_wrapper u_wrapper (
                .clk(clk),
                .d(a[i]),
                .q(y[i])
            );
        end
    endgenerate
endmodule

module sequential_bit_lane (
    input  logic clk,
    input  logic d,
    output logic q
);
    always_ff @(posedge clk) begin
        q <= d;
    end

    property p_tracks_previous_input;
        @(posedge clk) $past(d) == q;
    endproperty
    assert property (p_tracks_previous_input);

    property p_rejects_previous_input;
        @(posedge clk) $past(d) != q;
    endproperty
    assert property (p_rejects_previous_input);
endmodule

module sequential_child_output_bit_top (
    input  logic clk,
    input  logic [3:0] d,
    output logic [3:0] q
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            sequential_bit_lane u_lane (
                .clk(clk),
                .d(d[i]),
                .q(q[i])
            );
        end
    endgenerate
endmodule

module sequential_bit_wrapper (
    input  logic clk,
    input  logic d,
    output logic q
);
    sequential_bit_lane u_lane (
        .clk(clk),
        .d(d),
        .q(q)
    );
endmodule

module nested_sequential_child_output_bit_top (
    input  logic clk,
    input  logic [3:0] d,
    output logic [3:0] q
);
    generate
        for (genvar i = 0; i < 4; i = i + 1) begin : g_lane
            sequential_bit_wrapper u_wrapper (
                .clk(clk),
                .d(d[i]),
                .q(q[i])
            );
        end
    endgenerate
endmodule
