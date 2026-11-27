module xz_literal_reject (
    input  logic [3:0] a,
    output logic       match_x
);
    assign match_x = (a == 4'bx);
endmodule
