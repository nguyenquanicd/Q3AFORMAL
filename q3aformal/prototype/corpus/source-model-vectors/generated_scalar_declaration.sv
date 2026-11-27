module generated_declaration_top (
    input logic clk,
    input logic [3:0] a,
    output logic [3:0] y,
    input logic child_a,
    output logic child_y
);
    generated_declaration_child u_child (.a(child_a), .y(child_y));

    generate
        if (1) begin : g_active
            logic local_signal;
            assign local_signal = a[0];
            assign y[0] = local_signal;
        end
        for (genvar i = 1; i < 4; i = i + 1) begin : g_lane
            logic local_signal;
            assign local_signal = a[i];
            assign y[i] = local_signal;
        end
    endgenerate

    property p_generated_local_bus;
        @(posedge clk) y == a;
    endproperty
    property p_generated_child_local;
        @(posedge clk) child_y == child_a;
    endproperty
    assert property (p_generated_local_bus);
    assert property (p_generated_child_local);
endmodule

module generated_declaration_child (
    input logic a,
    output logic y
);
    generate
        if (1) begin : g_child
            logic local_signal;
            assign local_signal = a;
            assign y = local_signal;
        end
    endgenerate
endmodule

module generated_localparam_negative_top (
    input logic a,
    output logic y
);
    generate
        if (1) begin : g_localparam
            localparam logic ENABLED = 1'b1;
            localparam ENABLED = 1'b0;
            assign y = a;
        end
    endgenerate
endmodule

module generated_unscoped_declaration_negative_top (
    input logic a,
    output logic y
);
    generate
        if (1) logic local_signal;
    endgenerate
    assign y = a;
endmodule
