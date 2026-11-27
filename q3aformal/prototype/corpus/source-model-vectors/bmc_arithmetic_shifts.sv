module bmc_arithmetic_shifts_top (
    input logic clk,
    input logic [3:0] a,
    input logic [3:0] b,
    output logic [3:0] sum,
    output logic [3:0] difference,
    output logic [3:0] negated,
    output logic [3:0] shifted_left,
    output logic [3:0] shifted_right
);
    assign sum = a + b;
    assign difference = a - b;
    assign negated = -a;
    assign shifted_left = a << 1;
    assign shifted_right = a >> 1;

    property p_add_false;
        @(posedge clk) sum != (a + b);
    endproperty
    property p_sub_false;
        @(posedge clk) difference != (a - b);
    endproperty
    property p_neg_false;
        @(posedge clk) negated != -a;
    endproperty
    property p_shift_left_false;
        @(posedge clk) shifted_left != (a << 1);
    endproperty
    property p_shift_right_false;
        @(posedge clk) shifted_right != (a >> 1);
    endproperty

    assert property (p_add_false);
    assert property (p_sub_false);
    assert property (p_neg_false);
    assert property (p_shift_left_false);
    assert property (p_shift_right_false);
endmodule
