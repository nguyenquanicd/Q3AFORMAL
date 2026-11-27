module continuous_assignment_resize (
    input logic clk,
    output logic [3:0] y
);
    assign y = 8'd1;

    property p_assignment_truncation;
        @(posedge clk) y == 4'h1;
    endproperty
    assert property (p_assignment_truncation);
endmodule
