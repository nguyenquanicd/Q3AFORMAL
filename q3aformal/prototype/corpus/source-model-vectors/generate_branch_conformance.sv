module generate_branch_conformance #(
    parameter integer WIDTH = 4,
    parameter integer ENABLE = 1
) (
    input  logic             clk,
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    output logic [WIDTH-1:0] y
);
    generate
        if (ENABLE != 0) begin : g_enabled
            if (WIDTH == 4) begin : g_width_four
                assign y = a ^ b;
            end else begin : g_width_other
                assign y = a & b;
            end
        end else begin : g_disabled
            assign y = '0;
        end
    endgenerate

    property p_generated_behavior;
        @(posedge clk)
        (ENABLE == 0) ? (y == '0) :
        (WIDTH == 4) ? (y == (a ^ b)) : (y == (a & b));
    endproperty
    assert property (p_generated_behavior);
endmodule
