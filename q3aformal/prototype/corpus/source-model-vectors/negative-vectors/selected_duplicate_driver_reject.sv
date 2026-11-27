module selected_duplicate_driver_reject (
    input  logic a,
    input  logic b,
    output logic [3:0] y
);
    assign y[0] = a;
    assign y[1] = a;
    assign y[1] = b;
endmodule
