module sva_parameter_bounds #(
    parameter integer DELAY = 2,
    parameter integer REPEAT_COUNT = 2
) (
    input logic clk,
    input logic a,
    input logic b
);
    property p_parameter_delay;
        @(posedge clk) a ##DELAY b;
    endproperty

    property p_parameter_repeat;
        @(posedge clk) a[*REPEAT_COUNT];
    endproperty

    assert property (p_parameter_delay);
    cover property (p_parameter_repeat);
endmodule
