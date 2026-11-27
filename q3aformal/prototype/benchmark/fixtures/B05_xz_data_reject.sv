module xz_data_reject_bench (
    input  logic [3:0] data_in,
    output logic       match_x
);
    assign match_x = (data_in == 4'bx);
endmodule
