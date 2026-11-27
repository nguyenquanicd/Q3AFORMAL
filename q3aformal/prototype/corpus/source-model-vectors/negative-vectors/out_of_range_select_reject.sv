module out_of_range_select_reject (
    input  logic [3:0] data,
    output logic       result
);
    assign result = data[4];
endmodule
