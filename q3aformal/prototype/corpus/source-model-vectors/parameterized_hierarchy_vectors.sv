module parameterized_hierarchy_leaf #(
    parameter integer WIDTH = 2
) (
    input  logic [WIDTH-1:0] data_in,
    output logic [WIDTH-1:0] data_out
);
    localparam integer DATA_WIDTH = WIDTH;
    logic [DATA_WIDTH-1:0] data_mid;

    width_passthrough #(.WIDTH(WIDTH)) u_passthrough (
        .data_in(data_in),
        .data_out(data_mid)
    );
    assign data_out = data_mid;
endmodule

module width_passthrough #(
    parameter integer WIDTH = 2
) (
    input  logic [WIDTH-1:0] data_in,
    output logic [WIDTH-1:0] data_out
);
    assign data_out = data_in;
endmodule

module parameterized_hierarchy_top #(
    parameter integer WIDTH = 4
) (
    input  logic [WIDTH-1:0] data_in,
    output logic [WIDTH-1:0] data_out
);
    parameterized_hierarchy_leaf #(.WIDTH(WIDTH)) u_leaf (
        .data_in(data_in),
        .data_out(data_out)
    );
endmodule

module parameterized_hierarchy_positional_top #(
    parameter integer WIDTH = 4
) (
    input  logic [WIDTH-1:0] data_in,
    output logic [WIDTH-1:0] data_out
);
    parameterized_hierarchy_leaf #(WIDTH) u_leaf (
        .data_in(data_in),
        .data_out(data_out)
    );
endmodule

module parameterized_hierarchy_default_top (
    input  logic [1:0] data_in,
    output logic [1:0] data_out
);
    parameterized_hierarchy_leaf u_leaf (
        .data_in(data_in),
        .data_out(data_out)
    );
endmodule
