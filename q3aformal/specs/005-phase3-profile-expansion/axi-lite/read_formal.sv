module axi_lite_read_formal #(parameter FAULT = 0, LO = 0, HI = 7) (
    input logic clk, rst, arvalid, rready,
    input logic [3:0] araddr,
    input logic [31:0] word0, word1
);
    logic arready, rvalid;
    logic [31:0] rdata;
    logic [1:0] rresp;
    axi_lite_read_unit #(.FAULT(FAULT)) dut(.clk(clk), .rst(rst), .arvalid(arvalid),
        .rready(rready), .araddr(araddr), .word0(word0), .word1(word1),
        .arready(arready), .rvalid(rvalid), .rdata(rdata), .rresp(rresp));

    logic address_transfer, response_transfer, occupied, mapped;
    logic [7:0] expected_byte;
    logic control_matches, lane_matches;
    assign address_transfer = arvalid && arready;
    assign response_transfer = rvalid && rready;
    assign control_matches = (rvalid == occupied) && (arready == !occupied) &&
        (!occupied || (rresp == (mapped ? 2'b00 : 2'b11)));
    assign lane_matches = !occupied || (rdata[HI:LO] == expected_byte);

    // Record only sampled interface transfers and backing-store data.
    always_ff @(posedge clk) begin
        if (rst) begin
            occupied <= 1'b0;
            mapped <= 1'b0;
            expected_byte <= 8'd0;
        end else begin
            if (address_transfer) begin
                occupied <= 1'b1;
                mapped <= (araddr == 4'd0) || (araddr == 4'd4);
                expected_byte <= (araddr == 4'd0) ? word0[HI:LO] :
                    ((araddr == 4'd4) ? word1[HI:LO] : 8'd0);
            end
            if (response_transfer)
                occupied <= 1'b0;
        end
    end

    p_reset: assert property (@(posedge clk) rst |=> (control_matches && lane_matches));
    p_control_step: assert property (@(posedge clk) (!rst && control_matches) |=> control_matches);
    p_lane_step: assert property (@(posedge clk)
        (!rst && control_matches && lane_matches) |=> lane_matches);
    p_response_hold: assert property (@(posedge clk) (!rst && rvalid && !rready)
        |=> (rvalid && (rresp == $past(rresp)) && (rdata[HI:LO] == $past(rdata[HI:LO]))));

    a_address_hold: assume property (@(posedge clk) (!rst && arvalid && !arready)
        |=> (rst || (arvalid && (araddr == $past(araddr)))));

    c_first_word: cover property (@(posedge clk) rst ##1
        (!rst && address_transfer && (araddr == 4'd0) && (word0 != 32'd0))
        ##1 (!rst && response_transfer && (rresp == 2'b00) && (rdata == $past(word0))));
    c_second_word: cover property (@(posedge clk) rst ##1
        (!rst && address_transfer && (araddr == 4'd4) && (word1[31:24] != 8'd0))
        ##1 (!rst && response_transfer && (rresp == 2'b00) && (rdata == $past(word1))));
    c_unmapped: cover property (@(posedge clk) rst ##1
        (!rst && address_transfer && (araddr == 4'd1))
        ##1 (!rst && response_transfer && (rresp == 2'b11) && (rdata == 32'd0)));
    c_stall_and_retry: cover property (@(posedge clk) rst ##1
        (!rst && address_transfer && (araddr == 4'd0))
        ##1 (!rst && rvalid && !rready && arvalid && !arready && (araddr == 4'd4))
        ##1 (!rst && rvalid && !rready && (word0 != $past(word0)))
        ##1 (!rst && response_transfer && !arready)
        ##1 (!rst && address_transfer && (araddr == 4'd4))
        ##1 (!rst && response_transfer));
endmodule
