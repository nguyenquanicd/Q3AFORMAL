module rtl_single_driver (
    input  logic       clk,
    input  logic [3:0] a,
    output logic [3:0] y
);
    assign y = a;

    property p_single_driver_identity;
        @(posedge clk)
        y == a;
    endproperty

    assert property (p_single_driver_identity);
endmodule
