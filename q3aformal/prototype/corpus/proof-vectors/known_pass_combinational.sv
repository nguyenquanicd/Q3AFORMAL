module known_pass_top (
    input  logic clk,
    input  logic a,
    input  logic b,
    output logic y
);
    assign y = a && b;

    property p_y_implies_a;
        @(posedge clk) (!y || a);
    endproperty

    assert property (p_y_implies_a);
endmodule
