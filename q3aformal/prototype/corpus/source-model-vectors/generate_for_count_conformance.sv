module generate_for_count_conformance #(
    parameter integer COUNT = 0
) (
    input  logic clk,
    output logic is_one
);
    assign is_one = (COUNT == 1);

    generate
        for (genvar i = 0; i < COUNT; i = i + 1) begin : g_items
            logic present;
        end
    endgenerate

    property p_count_is_one;
        @(posedge clk) is_one == (COUNT == 1);
    endproperty
    assert property (p_count_is_one);
endmodule
