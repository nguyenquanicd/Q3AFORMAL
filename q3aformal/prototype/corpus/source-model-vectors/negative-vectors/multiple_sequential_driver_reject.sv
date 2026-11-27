module multiple_sequential_driver_reject (
    input  logic clk,
    input  logic a,
    input  logic b,
    output logic y
);
always_ff @(posedge clk) begin
    y <= a;
end
always_ff @(posedge clk) begin
    y <= b;
end
endmodule
