module axi_lite_read_unit #(parameter FAULT = 0) (
    input logic clk, rst, arvalid, rready,
    input logic [3:0] araddr,
    input logic [31:0] word0, word1,
    output logic arready, rvalid,
    output logic [31:0] rdata,
    output logic [1:0] rresp
);
    assign arready = !rvalid;
    always_ff @(posedge clk) begin
        if (rst) begin
            rvalid <= 1'b0;
            rdata <= 32'd0;
            rresp <= 2'b00;
        end else if (rvalid) begin
            if (rready || (FAULT == 3))
                rvalid <= 1'b0;
        end else if (arvalid) begin
            rvalid <= 1'b1;
            case (araddr)
                4'd0: begin
                    rdata <= word0;
                    rresp <= 2'b00;
                end
                4'd4: begin
                    rdata <= (FAULT == 1) ? {8'd0, word1[23:0]} : word1;
                    rresp <= 2'b00;
                end
                default: begin
                    rdata <= 32'd0;
                    rresp <= (FAULT == 2) ? 2'b00 : 2'b11;
                end
            endcase
        end
    end
endmodule
