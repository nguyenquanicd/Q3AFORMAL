module combinational_loop_reject (
    input  logic data_in,
    output logic data_out
);
    always_comb begin
        data_out = data_in & data_out;
    end
endmodule
