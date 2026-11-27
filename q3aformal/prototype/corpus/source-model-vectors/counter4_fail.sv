module counter4_fail (
    input  logic       clk,
    input  logic       rst,
    output logic [3:0] count
);
    always_ff @(posedge clk) begin
        if (rst) begin
            count <= 4'h0;
        end else if (count == 4'hF) begin
            count <= 4'h1;
        end else begin
            count <= count + 4'd1;
        end
    end

    property p_wraps_to_zero;
        @(posedge clk) (count == 4'hF) |=> (count == 4'h0);
    endproperty

    assert property (p_wraps_to_zero);
endmodule
