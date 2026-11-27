module bmc_cover_implication_top (
    input logic clk,
    input logic req,
    input logic data_valid,
    input logic ack
);
    property c_overlapped;
        @(posedge clk) req |-> ack;
    endproperty

    property c_nonoverlapped;
        @(posedge clk) req |=> ack;
    endproperty

    property c_sequence_antecedent;
        @(posedge clk) req ##1 data_valid |=> ack;
    endproperty

    property c_overlapped_range;
        @(posedge clk) req |-> ack[*1:2];
    endproperty

    property c_nonoverlapped_range;
        @(posedge clk) req |=> ack[*1:2];
    endproperty

    property c_nonoverlapped_minimum_two;
        @(posedge clk) req |=> ack[*2:3];
    endproperty

    property c_wide_repeat;
        @(posedge clk) ack[*1:256];
    endproperty

    property c_converging_repeat_paths;
        @(posedge clk) ack[*1:16] ##1 req[*1:16] ##1 data_valid[*1:16];
    endproperty

    cover property (c_overlapped);
    cover property (c_nonoverlapped);
    cover property (c_sequence_antecedent);
    cover property (c_overlapped_range);
    cover property (c_nonoverlapped_range);
    cover property (c_nonoverlapped_minimum_two);
    cover property (c_wide_repeat);
    cover property (c_converging_repeat_paths);
endmodule
