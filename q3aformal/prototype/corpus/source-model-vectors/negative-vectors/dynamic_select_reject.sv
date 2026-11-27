module dynamic_select_reject (
    input  logic [3:0] data,
    input  logic [1:0] index,
    output logic       result
);
    assign result = data[index];
endmodule
