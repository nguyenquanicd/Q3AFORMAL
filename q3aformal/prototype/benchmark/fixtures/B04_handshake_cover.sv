module handshake_cover_bench (
    input  logic       clk,
    input  logic       rst,
    input  logic       in_valid,
    output logic       in_ready,
    input  logic [3:0] in_data,
    output logic       out_valid,
    input  logic       out_ready,
    output logic [3:0] out_data
);
    logic       full;
    logic [3:0] data_q;

    assign in_ready = !full || out_ready;
    assign out_valid = full;
    assign out_data = data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            full  <= 1'b0;
            data_q <= 4'h0;
        end else if (in_ready) begin
            full <= in_valid;
            if (in_valid) begin
                data_q <= in_data;
            end
        end
    end

    property p_cover_transfer;
        @(posedge clk)
        (in_valid && in_ready && !rst) ##1 (out_valid && out_ready);
    endproperty

    cover property (p_cover_transfer);
endmodule
