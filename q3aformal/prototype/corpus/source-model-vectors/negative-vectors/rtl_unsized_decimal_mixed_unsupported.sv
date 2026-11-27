module rtl_unsized_decimal_mixed_unsupported (
    input  logic [7:0] input_value,
    output logic [7:0] output_value
);
    assign output_value = input_value * 3;
endmodule
