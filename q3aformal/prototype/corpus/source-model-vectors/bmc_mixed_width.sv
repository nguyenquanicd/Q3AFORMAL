module bmc_mixed_width_top (
    input logic clk,
    input logic [2:0] lhs,
    input logic [1:0] rhs,
    input logic signed [2:0] signed_lhs,
    input logic signed [1:0] signed_rhs,
    input logic select_rhs,
    output logic unsigned_lt,
    output logic unsigned_eq,
    output logic [2:0] unsigned_xor,
    output logic signed_lt,
    output logic signed [2:0] signed_sum,
    output logic signed [2:0] selected_signed
);
    logic [2:0] rhs_zero_extended;
    logic signed [2:0] signed_rhs_extended;

    assign rhs_zero_extended = {1'b0, rhs};
    assign signed_rhs_extended = {signed_rhs[1], signed_rhs};
    assign unsigned_lt = lhs < rhs;
    assign unsigned_eq = lhs == rhs;
    assign unsigned_xor = lhs ^ rhs;
    assign signed_lt = signed_lhs < signed_rhs;
    assign signed_sum = signed_lhs + signed_rhs;
    assign selected_signed = select_rhs ? signed_rhs : signed_lhs;

    property p_unsigned_relational_extension;
        @(posedge clk) unsigned_lt == (lhs < rhs_zero_extended);
    endproperty
    property p_unsigned_equality_extension;
        @(posedge clk) unsigned_eq == (lhs == rhs_zero_extended);
    endproperty
    property p_unsigned_bitwise_extension;
        @(posedge clk) unsigned_xor == (lhs ^ rhs_zero_extended);
    endproperty
    property p_signed_relational_extension;
        @(posedge clk) signed_lt == (signed_lhs < signed_rhs_extended);
    endproperty
    property p_signed_arithmetic_extension;
        @(posedge clk) signed_sum == (signed_lhs + signed_rhs_extended);
    endproperty
    property p_signed_conditional_extension;
        @(posedge clk) selected_signed ==
            (select_rhs ? signed_rhs_extended : signed_lhs);
    endproperty

    assert property (p_unsigned_relational_extension);
    assert property (p_unsigned_equality_extension);
    assert property (p_unsigned_bitwise_extension);
    assert property (p_signed_relational_extension);
    assert property (p_signed_arithmetic_extension);
    assert property (p_signed_conditional_extension);
endmodule
