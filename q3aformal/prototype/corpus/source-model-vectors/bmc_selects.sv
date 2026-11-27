module bmc_selects_top (
    input logic clk,
    input logic [7:0] down_vector,
    input logic [0:7] up_vector,
    output logic down_bit7,
    output logic down_bit0,
    output logic [3:0] down_low,
    output logic [3:0] down_high,
    output logic up_bit0,
    output logic up_bit7,
    output logic [3:0] up_first_half,
    output logic [3:0] up_second_half,
    output logic [3:0] down_constant_expression_half,
    output logic [7:0] down_shift0,
    output logic [7:0] down_shift4,
    output logic [7:0] down_shift7,
    output logic [7:0] up_shift0,
    output logic [7:0] up_shift4,
    output logic [7:0] up_shift7
);
    assign down_bit7 = down_vector[7];
    assign down_bit0 = down_vector[0];
    assign down_low = down_vector[3:0];
    assign down_high = down_vector[7:4];
    assign up_bit0 = up_vector[0];
    assign up_bit7 = up_vector[7];
    assign up_first_half = up_vector[0:3];
    assign up_second_half = up_vector[4:7];
    assign down_constant_expression_half = down_vector[1 + 2:0];
    assign down_shift0 = down_vector >> 0;
    assign down_shift4 = down_vector >> 4;
    assign down_shift7 = down_vector >> 7;
    assign up_shift0 = up_vector >> 0;
    assign up_shift4 = up_vector >> 4;
    assign up_shift7 = up_vector >> 7;

    property p_down_bit7_false;
        @(posedge clk) down_bit7 != down_vector[7];
    endproperty
    property p_down_low_false;
        @(posedge clk) down_low != down_vector[3:0];
    endproperty
    property p_down_high_false;
        @(posedge clk) down_high != down_vector[7:4];
    endproperty
    property p_up_bit0_false;
        @(posedge clk) up_bit0 != up_vector[0];
    endproperty
    property p_up_bit7_false;
        @(posedge clk) up_bit7 != up_vector[7];
    endproperty
    property p_up_first_half_false;
        @(posedge clk) up_first_half != up_vector[0:3];
    endproperty
    property p_up_second_half_false;
        @(posedge clk) up_second_half != up_vector[4:7];
    endproperty
    property p_down_constant_expression_half_false;
        @(posedge clk) down_constant_expression_half != down_vector[3:0];
    endproperty
    property p_map_down_bit7;
        @(posedge clk) down_bit7 == down_shift7[0];
    endproperty
    property p_map_down_bit0;
        @(posedge clk) down_bit0 == down_shift0[0];
    endproperty
    property p_map_down_low;
        @(posedge clk) down_low == down_shift0[3:0];
    endproperty
    property p_map_down_high;
        @(posedge clk) down_high == down_shift4[3:0];
    endproperty
    property p_map_up_bit0;
        @(posedge clk) up_bit0 == up_shift7[0];
    endproperty
    property p_map_up_bit7;
        @(posedge clk) up_bit7 == up_shift0[0];
    endproperty
    property p_map_up_first_half;
        @(posedge clk) up_first_half == up_shift4[3:0];
    endproperty
    property p_map_up_second_half;
        @(posedge clk) up_second_half == up_shift0[3:0];
    endproperty

    assert property (p_down_bit7_false);
    assert property (p_down_low_false);
    assert property (p_down_high_false);
    assert property (p_up_bit0_false);
    assert property (p_up_bit7_false);
    assert property (p_up_first_half_false);
    assert property (p_up_second_half_false);
    assert property (p_down_constant_expression_half_false);
    assert property (p_map_down_bit7);
    assert property (p_map_down_bit0);
    assert property (p_map_down_low);
    assert property (p_map_down_high);
    assert property (p_map_up_bit0);
    assert property (p_map_up_bit7);
    assert property (p_map_up_first_half);
    assert property (p_map_up_second_half);
endmodule
