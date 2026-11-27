module rtl_packed_type_boundaries (
    input logic clk,
    input bit signed [0:0] narrow_in,
    input logic signed [0:63] signed_in,
    input bit [63:0] unsigned_in,
    output bit signed [0:0] narrow_out,
    output logic signed [63:0] signed_out,
    output bit [0:63] unsigned_out
);
    assign narrow_out = narrow_in;
    assign signed_out = signed_in;
    assign unsigned_out = unsigned_in;

    property p_narrow_copy; @(posedge clk) narrow_out == narrow_in; endproperty
    property p_signed_msb; @(posedge clk) signed_out[63] == signed_in[0]; endproperty
    property p_unsigned_msb; @(posedge clk) unsigned_out[0] == unsigned_in[63]; endproperty
    property p_signed_negative; @(posedge clk) (signed_out < 64'sd0) == signed_in[0]; endproperty
    property p_unsigned_nonnegative; @(posedge clk) unsigned_out >= 64'd0; endproperty
    property p_false_signed_nonnegative; @(posedge clk) signed_out >= 64'sd0; endproperty

    assert property (p_narrow_copy);
    assert property (p_signed_msb);
    assert property (p_unsigned_msb);
    assert property (p_signed_negative);
    assert property (p_unsigned_nonnegative);
    assert property (p_false_signed_nonnegative);
endmodule
