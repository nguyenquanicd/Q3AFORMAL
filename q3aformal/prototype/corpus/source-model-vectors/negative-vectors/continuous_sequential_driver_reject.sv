module continuous_sequential_driver_reject (
    input  logic clk,
    input  logic a,
    output logic y
);
always_ff @(posedge clk) begin
    y <= a;
end
assign y = a;
endmodule
