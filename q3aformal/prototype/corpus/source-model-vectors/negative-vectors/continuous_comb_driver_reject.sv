module continuous_comb_driver_reject (
    input  logic a,
    output logic y
);
always_comb begin
    y = a;
end
assign y = ~a;
endmodule
