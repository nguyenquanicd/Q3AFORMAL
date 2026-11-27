module latch_inference_reject (
    input  logic enable,
    input  logic data_in,
    output logic data_out
);
    always_comb begin
        if (enable) begin
            data_out = data_in;
        end
    end
endmodule
