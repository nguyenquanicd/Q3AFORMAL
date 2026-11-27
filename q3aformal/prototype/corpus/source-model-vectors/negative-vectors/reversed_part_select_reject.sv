module reversed_part_select_reject (
    input  logic [7:0] data,
    output logic [3:0] result
);
    assign result = data[0:3];
endmodule
