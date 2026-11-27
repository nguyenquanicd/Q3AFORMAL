module p2_transport_encoded(
    input logic clock,
    input logic [7:0] value,
    output logic [7:0] result
);
    logic [7:0] enc0, enc1, enc2, enc3;
    always_ff @(posedge clock) begin
        enc0 <= ~value;
        enc1 <= enc0;
        enc2 <= enc1;
        enc3 <= enc2;
    end
    assign result = ~enc3;
endmodule
