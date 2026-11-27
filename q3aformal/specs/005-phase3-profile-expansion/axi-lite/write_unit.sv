module axi_lite_write_unit #(parameter FAULT = 0) (
    input logic clk, rst, awvalid, wvalid, bready,
    input logic [3:0] awaddr, wstrb,
    input logic [31:0] wdata,
    output logic awready, wready, bvalid,
    output logic [1:0] bresp,
    output logic [31:0] reg0, reg1,
    output logic aw_pending, w_pending,
    output logic [3:0] saved_addr, saved_strb,
    output logic [31:0] saved_data
);
    logic aw_fire, w_fire;
    logic [3:0] addr, strb;
    logic [31:0] payload;

    assign awready = !bvalid && !aw_pending;
    assign wready = !bvalid && !w_pending;
    assign aw_fire = awvalid && awready;
    assign w_fire = wvalid && wready;
    assign addr = aw_pending ? saved_addr : awaddr;
    assign payload = w_pending ? saved_data : wdata;
    assign strb = w_pending ? saved_strb : wstrb;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            saved_addr <= 4'd0;
            saved_strb <= 4'd0;
            saved_data <= 32'd0;
            bvalid <= 1'b0;
            bresp <= 2'b00;
            reg0 <= 32'd0;
            reg1 <= 32'd0;
        end else if (bvalid) begin
            if (bready || (FAULT == 3)) bvalid <= 1'b0;
        end else if ((aw_pending || aw_fire) && (w_pending || w_fire || (FAULT == 1))) begin
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            bvalid <= 1'b1;
            bresp <= ((addr == 4'd0) || (addr == 4'd4)) ? 2'b00 : 2'b11;
            if (addr == 4'd0) begin
                reg0 <= {(strb[3] || (FAULT == 2)) ? payload[31:24] : reg0[31:24],
                    strb[2] ? payload[23:16] : reg0[23:16],
                    strb[1] ? payload[15:8] : reg0[15:8],
                    strb[0] ? payload[7:0] : reg0[7:0]};
            end else if (addr == 4'd4) begin
                reg1 <= {(strb[3] || (FAULT == 2)) ? payload[31:24] : reg1[31:24],
                    strb[2] ? payload[23:16] : reg1[23:16],
                    strb[1] ? payload[15:8] : reg1[15:8],
                    strb[0] ? payload[7:0] : reg1[7:0]};
            end
        end else begin
            if (aw_fire) begin
                aw_pending <= 1'b1;
                saved_addr <= awaddr;
            end
            if (w_fire) begin
                w_pending <= 1'b1;
                saved_strb <= wstrb;
                saved_data <= wdata;
            end
        end
    end
endmodule
