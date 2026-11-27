module rtl_017_arithmetic_right_shift (
    input logic clk,
    input logic signed [3:0] s,
    input logic [3:0] u
);
    property p_signed_asr_0; @(posedge clk) (s >>> 0) == s; endproperty
    property p_signed_asr_1; @(posedge clk) (s >>> 1) == {s[3], s[3:1]}; endproperty
    property p_signed_asr_2; @(posedge clk) (s >>> 2) == {s[3], s[3], s[3:2]}; endproperty
    property p_signed_asr_3; @(posedge clk) (s >>> 3) == {s[3], s[3], s[3], s[3]}; endproperty
    property p_signed_asr_4; @(posedge clk) (s >>> 4) == {s[3], s[3], s[3], s[3]}; endproperty
    property p_signed_asr_5; @(posedge clk) (s >>> 5) == {s[3], s[3], s[3], s[3]}; endproperty
    property p_signed_asr_6; @(posedge clk) (s >>> 6) == {s[3], s[3], s[3], s[3]}; endproperty
    property p_signed_asr_7; @(posedge clk) (s >>> 7) == {s[3], s[3], s[3], s[3]}; endproperty

    property p_unsigned_asr_0; @(posedge clk) (u >>> 0) == u; endproperty
    property p_unsigned_asr_1; @(posedge clk) (u >>> 1) == {1'b0, u[3:1]}; endproperty
    property p_unsigned_asr_2; @(posedge clk) (u >>> 2) == {2'b00, u[3:2]}; endproperty
    property p_unsigned_asr_3; @(posedge clk) (u >>> 3) == {3'b000, u[3]}; endproperty
    property p_unsigned_asr_4; @(posedge clk) (u >>> 4) == 4'b0000; endproperty
    property p_unsigned_asr_5; @(posedge clk) (u >>> 5) == 4'b0000; endproperty
    property p_unsigned_asr_6; @(posedge clk) (u >>> 6) == 4'b0000; endproperty
    property p_unsigned_asr_7; @(posedge clk) (u >>> 7) == 4'b0000; endproperty

    assert property (p_signed_asr_0);
    assert property (p_signed_asr_1);
    assert property (p_signed_asr_2);
    assert property (p_signed_asr_3);
    assert property (p_signed_asr_4);
    assert property (p_signed_asr_5);
    assert property (p_signed_asr_6);
    assert property (p_signed_asr_7);
    assert property (p_unsigned_asr_0);
    assert property (p_unsigned_asr_1);
    assert property (p_unsigned_asr_2);
    assert property (p_unsigned_asr_3);
    assert property (p_unsigned_asr_4);
    assert property (p_unsigned_asr_5);
    assert property (p_unsigned_asr_6);
    assert property (p_unsigned_asr_7);
endmodule
