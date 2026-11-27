module axi_lite_write_formal #(parameter FAULT = 0, LANE = 0, LO = 0, HI = 7) (
    input logic clk, rst, awvalid, wvalid, bready,
    input logic [3:0] awaddr, wstrb,
    input logic [31:0] wdata
);
    logic awready, wready, bvalid;
    logic [1:0] bresp;
    logic [31:0] reg0, reg1;
    logic aw_pending, w_pending;
    logic [3:0] saved_addr, saved_strb;
    logic [31:0] saved_data;
    axi_lite_write_unit #(.FAULT(FAULT)) dut(.clk(clk), .rst(rst), .awvalid(awvalid),
        .wvalid(wvalid), .bready(bready), .awaddr(awaddr), .wstrb(wstrb), .wdata(wdata),
        .awready(awready), .wready(wready), .bvalid(bvalid), .bresp(bresp),
        .reg0(reg0), .reg1(reg1), .aw_pending(aw_pending), .w_pending(w_pending),
        .saved_addr(saved_addr), .saved_strb(saved_strb), .saved_data(saved_data));

    logic seen_aw, seen_w, have_response;
    logic aw_fire, w_fire, take_pair;
    logic [3:0] transaction_addr, reference_addr;
    logic [7:0] transaction_byte, reference_byte, expected0, expected1;
    logic transaction_enable, reference_enable;
    logic match_control, match_lane;

    assign aw_fire = awvalid && awready;
    assign w_fire = wvalid && wready;
    assign have_response = seen_aw && seen_w;
    assign take_pair = !have_response && (seen_aw || aw_fire) && (seen_w || w_fire);
    assign transaction_addr = aw_fire ? awaddr : reference_addr;
    assign transaction_byte = w_fire ? wdata[HI:LO] : reference_byte;
    assign transaction_enable = w_fire ? wstrb[LANE] : reference_enable;

    // The scoreboard collects accepted channel items until the response retires.
    always_ff @(posedge clk) begin
        if (rst) begin
            seen_aw <= 1'b0;
            seen_w <= 1'b0;
            reference_addr <= 4'd0;
            reference_byte <= 8'd0;
            reference_enable <= 1'b0;
            expected0 <= 8'd0;
            expected1 <= 8'd0;
        end else begin
            if (have_response && bready) begin
                seen_aw <= 1'b0;
                seen_w <= 1'b0;
            end else begin
                if (aw_fire) begin
                    seen_aw <= 1'b1;
                    reference_addr <= awaddr;
                end
                if (w_fire) begin
                    seen_w <= 1'b1;
                    reference_byte <= wdata[HI:LO];
                    reference_enable <= wstrb[LANE];
                end
            end
            if (take_pair && transaction_enable && (transaction_addr == 4'd0))
                expected0 <= transaction_byte;
            if (take_pair && transaction_enable && (transaction_addr == 4'd4))
                expected1 <= transaction_byte;
        end
    end

    assign match_control = (bvalid == have_response) &&
        (awready == (!seen_aw && !have_response)) &&
        (wready == (!seen_w && !have_response)) &&
        (aw_pending == (seen_aw && !have_response)) &&
        (w_pending == (seen_w && !have_response)) &&
        (!aw_pending || (saved_addr == reference_addr)) &&
        (!bvalid || (bresp == (((reference_addr == 4'd0) || (reference_addr == 4'd4)) ? 2'b00 : 2'b11)));
    assign match_lane = (reg0[HI:LO] == expected0) && (reg1[HI:LO] == expected1) &&
        (!w_pending || ((saved_data[HI:LO] == reference_byte) && (saved_strb[LANE] == reference_enable)));

    // Observe the implementation's private state only in the inductive relation.
    p_reset: assert property (@(posedge clk) rst |=> (match_control && match_lane));
    p_control_step: assert property (@(posedge clk) (!rst && match_control) |=> match_control);
    p_lane_step: assert property (@(posedge clk) (!rst && match_control && match_lane) |=> match_lane);
    p_response_hold: assert property (@(posedge clk) (!rst && bvalid && !bready)
        |=> (bvalid && (bresp == $past(bresp))));

    a_address_hold: assume property (@(posedge clk) (!rst && awvalid && !awready)
        |=> (rst || (awvalid && (awaddr == $past(awaddr)))));
    a_data_hold: assume property (@(posedge clk) (!rst && wvalid && !wready)
        |=> (rst || (wvalid && (wdata == $past(wdata)) && (wstrb == $past(wstrb)))));

    c_address_first: cover property (@(posedge clk) rst ##1
        (!rst && aw_fire && !w_fire) ##1 (!rst && w_fire) ##1 (!rst && bvalid && bready));
    c_data_first: cover property (@(posedge clk) rst ##1
        (!rst && w_fire && !aw_fire) ##1 (!rst && aw_fire) ##1 (!rst && bvalid && bready));
    c_same_sample: cover property (@(posedge clk) rst ##1
        (!rst && aw_fire && w_fire) ##1 (!rst && bvalid && bready));
    c_backpressure: cover property (@(posedge clk) rst ##1 (!rst && aw_fire && w_fire)
        ##1 (!rst && bvalid && !bready) ##1 (!rst && bvalid && !bready) ##1 (!rst && bvalid && bready));
    c_unmapped: cover property (@(posedge clk) rst ##1
        (!rst && aw_fire && w_fire && (awaddr == 4'd8)) ##1 (!rst && bvalid && (bresp == 2'b11)));
    c_zero_strobes: cover property (@(posedge clk) rst ##1
        (!rst && aw_fire && w_fire && (awaddr == 4'd4) && (wstrb == 4'd0) && (wdata != 32'd0))
        ##1 (!rst && bvalid && (bresp == 2'b00) && (reg1 == 32'd0)));
endmodule
