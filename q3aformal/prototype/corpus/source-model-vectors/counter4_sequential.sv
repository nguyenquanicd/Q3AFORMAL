module counter4_sequential (
    input  logic       clk,
    input  logic       rst,
    output logic [3:0] count
);
    always_ff @(posedge clk) begin
        if (rst) begin
            count <= 4'h0;
        end else if (count == 4'hF) begin
            count <= 4'h0;
        end else begin
            count <= count + 4'd1;
        end
    end
endmodule
