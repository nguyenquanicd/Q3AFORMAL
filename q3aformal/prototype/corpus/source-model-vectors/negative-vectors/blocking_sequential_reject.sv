module blocking_sequential_reject (
    input  logic clk,
    input  logic data_in,
    output logic state_q
);
    always_ff @(posedge clk) begin
        state_q = data_in;
    end
endmodule
