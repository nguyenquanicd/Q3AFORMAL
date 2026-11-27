module rtl_sized_literal_resize (
    input  logic       clk,
    output logic [7:0] based_binary,
    output logic [7:0] based_octal,
    output logic [7:0] based_decimal,
    output logic [7:0] based_hex,
    output logic [7:0] based_signed_binary,
    output logic [7:0] based_signed_octal,
    output logic [7:0] based_signed_decimal,
    output logic [7:0] based_signed_hex,
    output logic signed [7:0] based_signed,
    output logic [7:0] unsigned_zero_extend,
    output logic [7:0] unsigned_zero_extend_comb,
    output logic signed [7:0] signed_sign_extend,
    output logic signed [7:0] signed_sign_extend_state,
    output logic [3:0] unsigned_truncate
);
    assign based_binary = 8'b0101_0110;
    assign based_octal = 8'o126;
    assign based_decimal = 8'd86;
    assign based_hex = 8'h56;
    assign based_signed_binary = 8'sb0101_0110;
    assign based_signed_octal = 8'so126;
    assign based_signed_decimal = 8'sd86;
    assign based_signed_hex = 8'sh56;
    assign based_signed = 8'sd86;
    assign unsigned_zero_extend = 4'b1010;
    assign signed_sign_extend = 4'sb1110;
    assign unsigned_truncate = 8'hA6;

    always_comb begin
        unsigned_zero_extend_comb = 4'b1010;
    end

    always_ff @(posedge clk) begin
        signed_sign_extend_state <= 4'sb1110;
    end

    property p_sized_literal_constants;
        @(posedge clk)
        (based_binary == 8'h56) &&
        (based_octal == 8'h56) &&
        (based_decimal == 8'h56) &&
        (based_hex == 8'h56) &&
        (based_signed_binary == 8'h56) &&
        (based_signed_octal == 8'h56) &&
        (based_signed_decimal == 8'h56) &&
        (based_signed_hex == 8'h56) &&
        (unsigned_zero_extend == 8'h0A) &&
        (unsigned_zero_extend_comb == 8'h0A) &&
        (signed_sign_extend == 8'hFE) &&
        (unsigned_truncate == 4'h6);
    endproperty
    assert property (p_sized_literal_constants);

    property p_sized_literal_sequential_resize;
        @(posedge clk) 1'b1 |=> (signed_sign_extend_state == 8'hFE);
    endproperty
    assert property (p_sized_literal_sequential_resize);
endmodule
