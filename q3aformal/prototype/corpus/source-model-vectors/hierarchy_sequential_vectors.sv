module hierarchy_toggle_leaf (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    output logic value
);
    logic value_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            value_q <= 1'b0;
        end else if (enable) begin
            value_q <= !value_q;
        end
    end

    assign value = value_q;
endmodule

module hierarchy_toggle_top (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    output logic value
);
    hierarchy_toggle_leaf u_toggle (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .value(value)
    );
endmodule

module hierarchy_multiple_instances_top (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    output logic left_value,
    output logic right_value
);
    hierarchy_toggle_leaf u_left (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .value(left_value)
    );

    hierarchy_toggle_leaf u_right (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .value(right_value)
    );
endmodule

module hierarchy_nested_toggle_middle (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    output logic value
);
    hierarchy_toggle_leaf u_toggle (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .value(value)
    );
endmodule

module hierarchy_nested_toggle_top (
    input  logic clk,
    input  logic rst,
    input  logic enable,
    output logic value
);
    hierarchy_nested_toggle_middle u_middle (
        .clk(clk),
        .rst(rst),
        .enable(enable),
        .value(value)
    );
endmodule
