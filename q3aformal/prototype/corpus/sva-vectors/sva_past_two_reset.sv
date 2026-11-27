module sva_past_two_reset (
    input logic clk,
    input logic rst,
    input logic a,
    input logic b,
    output logic q
);
    always_ff @(posedge clk) begin
        if (rst) begin
            q <= 1'b0;
        end else begin
            q <= a;
        end
    end

    assume property (@(posedge clk) rst);

    property p_past_one;
        @(posedge clk) $past(a) |-> b;
    endproperty

    property p_past_two;
        @(posedge clk) $past(a, 2) |-> b;
    endproperty

    assert property (p_past_one);
    assert property (p_past_two);
endmodule
