module sva_assertion_conformance (
    input logic clk,
    input logic a
);
    property p_known_true;
        @(posedge clk) (a || !a);
    endproperty
    assert property (p_known_true);

    property p_known_false;
        @(posedge clk) a;
    endproperty
    assert property (p_known_false);
endmodule
