module p2_transport_stage(
    input logic clk,
    input logic [7:0] data_in,
    output logic [7:0] data_out
);
    always_ff @(posedge clk) begin
        data_out <= data_in;
    end
endmodule

module p2_transport_subsystem(
    input logic clk,
    input logic [7:0] data_in,
    output logic [7:0] data_out
);
    logic [7:0] lane0, lane1, lane2;
    p2_transport_stage stage0(clk, data_in, lane0);
    p2_transport_stage stage1(clk, lane0, lane1);
    p2_transport_stage stage2(clk, lane1, lane2);
    p2_transport_stage stage3(clk, lane2, data_out);

    p_stage0: assert property (@(posedge clk) lane0 == $past(data_in));
    p_stage1: assert property (@(posedge clk) lane1 == $past(lane0));
    p_stage2: assert property (@(posedge clk) lane2 == $past(lane1));
    p_stage3: assert property (@(posedge clk) data_out == $past(lane2));
    p_subsystem: assert property (@(posedge clk)
        (lane0 == $past(data_in)) && (lane1 == $past(lane0)) &&
        (lane2 == $past(lane1)) && (data_out == $past(lane2)));
endmodule
