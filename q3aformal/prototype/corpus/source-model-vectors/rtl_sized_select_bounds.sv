module rtl_sized_select_bounds(
    input logic clk,
    input logic [7:0] input_bits,
    input logic [0:7] ascending_bits
);
    logic bit_after_wrap;
    logic bit_after_underflow;
    logic mixed_index;
    logic [2:0] descending_part;
    logic [2:0] ascending_part;
    logic [7:0] selected_targets;
    logic [7:0] bitwise_targets;
    logic [2:0] bitwise_ascending_part;
    logic context_index;
    logic concatenated_index;

    assign bit_after_wrap = input_bits[3'd7 + 3'd2];
    assign bit_after_underflow = input_bits[3'd0 - 3'd1];
    assign mixed_index = input_bits[3'sb111 + 4'd0];
    assign descending_part = input_bits[(2'd3 + 2'd1) + 3'd2 : 3'd4];
    assign ascending_part = ascending_bits[2'd1 - 2'd1 : 3'd7 + 3'd3];
    assign selected_targets[3'd7 + 3'd1] = input_bits[0];
    assign selected_targets[7:1] = input_bits[7:1];
    assign bitwise_targets[(3'd7 & 3'd0)] = input_bits[0];
    assign bitwise_targets[(3'd7 | 3'd0) : ~(3'b110)] = input_bits[7:1];
    assign bitwise_ascending_part = ascending_bits[3'd2 ^ 3'd2 : 3'd7 ^~ 3'd2];
    assign context_index = input_bits[((3'sb100 < 4'sd0) && (3'sb100 != 4'd12))
        ? ((3'sb110 >> 1'b1) | (3'sd1 << 7'd64)) : 3'sd0];
    assign concatenated_index = input_bits[{1'b1, '0}];

    property p_expected; @(posedge clk)
        (bit_after_wrap == input_bits[1]) &&
        (bit_after_underflow == input_bits[7]) &&
        (mixed_index == input_bits[7]) &&
        (descending_part == input_bits[6:4]) &&
        (ascending_part == ascending_bits[0:2]) &&
        (selected_targets == input_bits) &&
        (bitwise_targets == input_bits) &&
        (bitwise_ascending_part == ascending_bits[0:2]) &&
        (context_index == input_bits[3]) && (concatenated_index == input_bits[2]);
    endproperty
    property p_wrong_index; @(posedge clk)
        bit_after_wrap == input_bits[0];
    endproperty
    property p_wrong_bitwise_range; @(posedge clk)
        bitwise_ascending_part == ascending_bits[1:3];
    endproperty
    assert property (p_expected);
    assert property (p_wrong_index);
    assert property (p_wrong_bitwise_range);
endmodule
