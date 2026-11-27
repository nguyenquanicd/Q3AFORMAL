module multiple_driver_reject (
    input  logic a,
    input  logic b,
    output logic y
);
    assign y = a;
    assign y = b;
endmodule
