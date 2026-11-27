module combinational_word_lane (
    input  logic [3:0] d,
    output logic [3:0] q
);
    assign q = d ^ 4'hA;
endmodule

module combinational_word_wrapper (
    input  logic [3:0] d,
    output logic [3:0] q
);
    combinational_word_lane u_lane (
        .d(d),
        .q(q)
    );
endmodule

module combinational_part_select_direct_top (
    input  logic       clk,
    input  logic [7:0] d,
    output logic [7:0] q
);
    combinational_word_lane u_low (
        .d(d[3:0]),
        .q(q[3:0])
    );
    combinational_word_lane u_high (
        .d(d[7:4]),
        .q(q[7:4])
    );

    property p_maps_outputs;
        @(posedge clk) q == (d ^ 8'hAA);
    endproperty
    assert property (p_maps_outputs);
endmodule

module combinational_part_select_nested_top (
    input  logic       clk,
    input  logic [7:0] d,
    output logic [7:0] q
);
    combinational_word_wrapper u_low (
        .d(d[3:0]),
        .q(q[3:0])
    );
    combinational_word_wrapper u_high (
        .d(d[7:4]),
        .q(q[7:4])
    );

    property p_maps_outputs;
        @(posedge clk) q == (d ^ 8'hAA);
    endproperty
    assert property (p_maps_outputs);
endmodule

module combinational_part_select_ascending_direct_top (
    input  logic       clk,
    input  logic [0:7] d,
    output logic [0:7] q
);
    combinational_word_lane u_low (
        .d(d[0:3]),
        .q(q[0:3])
    );
    combinational_word_lane u_high (
        .d(d[4:7]),
        .q(q[4:7])
    );

    property p_maps_outputs;
        @(posedge clk) q == (d ^ 8'hAA);
    endproperty
    assert property (p_maps_outputs);
endmodule

module combinational_part_select_ascending_nested_top (
    input  logic       clk,
    input  logic [0:7] d,
    output logic [0:7] q
);
    combinational_word_wrapper u_low (
        .d(d[0:3]),
        .q(q[0:3])
    );
    combinational_word_wrapper u_high (
        .d(d[4:7]),
        .q(q[4:7])
    );

    property p_maps_outputs;
        @(posedge clk) q == (d ^ 8'hAA);
    endproperty
    assert property (p_maps_outputs);
endmodule
