module p1_elastic_stage #(parameter BROKEN = 0) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    output logic in_ready,
    input logic [15:0] in_data,
    output logic out_valid,
    input logic out_ready,
    output logic [15:0] out_data
);
    assign in_ready = !out_valid || out_ready;
    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            out_data <= 16'h0000;
        end else if (in_ready || BROKEN != 0) begin
            out_valid <= in_valid;
            if (in_valid) out_data <= in_data;
        end
    end
endmodule

module p1_elastic_pipeline #(parameter DROP_STALL = 0) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    output logic in_ready,
    input logic [15:0] in_data,
    output logic out_valid,
    input logic out_ready,
    output logic [15:0] out_data
);
    logic valid_0;
    logic valid_1;
    logic valid_2;
    logic ready_1;
    logic ready_2;
    logic ready_3;
    logic [15:0] data_0;
    logic [15:0] data_1;
    logic [15:0] data_2;
    p1_elastic_stage u_0(.clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .in_data(in_data), .out_valid(valid_0), .out_ready(ready_1), .out_data(data_0));
    p1_elastic_stage u_1(.clk(clk), .rst(rst), .in_valid(valid_0), .in_ready(ready_1),
        .in_data(data_0), .out_valid(valid_1), .out_ready(ready_2), .out_data(data_1));
    p1_elastic_stage u_2(.clk(clk), .rst(rst), .in_valid(valid_1), .in_ready(ready_2),
        .in_data(data_1), .out_valid(valid_2), .out_ready(ready_3), .out_data(data_2));
    p1_elastic_stage #(.BROKEN(DROP_STALL)) u_3(.clk(clk), .rst(rst),
        .in_valid(valid_2), .in_ready(ready_3), .in_data(data_2),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data));

    p_hold: assert property (@(posedge clk)
        (!rst && out_valid && !out_ready) |=> (out_valid && out_data == $past(out_data)));
    p_transfer: cover property (@(posedge clk)
        rst ##1 (!rst && in_valid && in_ready) ##4 (!rst && out_valid && out_ready));
endmodule
