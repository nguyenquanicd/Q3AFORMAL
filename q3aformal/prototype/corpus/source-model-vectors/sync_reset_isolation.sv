module sync_reset_isolation (
    input  logic clk,
    input  logic rst,
    input  logic data_in,
    output logic reset_q,
    output logic free_q
);
    always_ff @(posedge clk) begin
        if (rst) begin
            reset_q <= 1'b0;
        end else begin
            reset_q <= data_in;
        end
        free_q <= data_in;
    end
endmodule
