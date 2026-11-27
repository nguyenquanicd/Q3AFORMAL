module rtl_unsized_decimal_runtime_concat (
    input logic in_bit,
    output logic [32:0] bits
);
    assign bits = {in_bit, 7};
endmodule
