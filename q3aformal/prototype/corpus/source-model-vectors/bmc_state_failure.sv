module bmc_state_failure_top (
    input logic clk,
    input logic rst,
    input logic a,
    output logic q
);
    always_ff @(posedge clk) begin
        if (rst) begin
            q <= 1'b0;
        end else begin
            q <= 1'b0;
        end
    end

    property p_q_tracks_a;
        @(posedge clk) (a && !rst) |=> (!rst && q);
    endproperty

    assert property (p_q_tracks_a);
endmodule
