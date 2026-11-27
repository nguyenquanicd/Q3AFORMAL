module sequential_word_lane (
    input  logic       clk,
    input  logic [3:0] d,
    output logic [3:0] q
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

module sequential_part_select_direct_top (
    input  logic       clk,
    input  logic [7:0] d,
    output logic [7:0] q
);
    sequential_word_lane u_low (
        .clk(clk),
        .d(d[3:0]),
        .q(q[3:0])
    );
    sequential_word_lane u_high (
        .clk(clk),
        .d(d[7:4]),
        .q(q[7:4])
    );
endmodule

module sequential_word_wrapper (
    input  logic       clk,
    input  logic [3:0] d,
    output logic [3:0] q
);
    sequential_word_lane u_lane (
        .clk(clk),
        .d(d),
        .q(q)
    );
endmodule

module sequential_part_select_nested_top (
    input  logic       clk,
    input  logic [7:0] d,
    output logic [7:0] q
);
    sequential_word_wrapper u_low (
        .clk(clk),
        .d(d[3:0]),
        .q(q[3:0])
    );
    sequential_word_wrapper u_high (
        .clk(clk),
        .d(d[7:4]),
        .q(q[7:4])
    );
endmodule

module sequential_part_select_ascending_direct_top (
    input  logic       clk,
    input  logic [0:7] d,
    output logic [0:7] q
);
    sequential_word_lane u_low (
        .clk(clk),
        .d(d[0:3]),
        .q(q[0:3])
    );
    sequential_word_lane u_high (
        .clk(clk),
        .d(d[4:7]),
        .q(q[4:7])
    );
endmodule

module sequential_part_select_ascending_nested_top (
    input  logic       clk,
    input  logic [0:7] d,
    output logic [0:7] q
);
    sequential_word_wrapper u_low (
        .clk(clk),
        .d(d[0:3]),
        .q(q[0:3])
    );
    sequential_word_wrapper u_high (
        .clk(clk),
        .d(d[4:7]),
        .q(q[4:7])
    );
endmodule

module sequential_part_select_bad_width_top (
    input  logic       clk,
    input  logic [3:0] d,
    output logic [3:0] q
);
    sequential_word_lane u_bad_width (
        .clk(clk),
        .d(d),
        .q(q[2:0])
    );
endmodule

module sequential_part_select_bad_direction_top (
    input  logic       clk,
    input  logic [3:0] d,
    output logic [3:0] q
);
    sequential_word_lane u_bad_direction (
        .clk(clk),
        .d(d),
        .q(q[0:3])
    );
endmodule

module sequential_part_select_incomplete_top (
    input  logic       clk,
    input  logic [3:0] d,
    output logic [7:0] q
);
    sequential_word_lane u_low (
        .clk(clk),
        .d(d),
        .q(q[3:0])
    );
endmodule

module sequential_part_select_duplicate_top (
    input  logic       clk,
    input  logic [3:0] d,
    output logic [7:0] q
);
    sequential_word_lane u_first (
        .clk(clk),
        .d(d),
        .q(q[3:0])
    );
    sequential_word_lane u_second (
        .clk(clk),
        .d(d),
        .q(q[3:0])
    );
endmodule
