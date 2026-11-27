module multiple_process_driver_reject (
    input  logic a,
    input  logic b,
    output logic y
);
always_comb begin
    y = a;
end
always_comb begin
    y = b;
end
endmodule
