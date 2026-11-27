module scalar_clock_review #(
    parameter SERIALIZE_JOINT_EDGE = 0,
    parameter ADVANCE_ON_PEER_EDGE = 0
) (
    input logic step_clock,
    input logic edge_a, edge_b,
    input logic reset_a, reset_b,
    output logic x, y,
    output logic previous_a, older_a
);
    // Model masks as ordinary inputs of the supported single global step.
    logic next_x;
    assign next_x = reset_a ? 1'b0 : y;

    always_ff @(posedge step_clock) begin
        if (edge_a) x <= next_x;
        if (edge_b) begin
            if (reset_b) y <= 1'b0;
            else if (SERIALIZE_JOINT_EDGE != 0 && edge_a) y <= next_x;
            else y <= x;
        end
        if (edge_a || (ADVANCE_ON_PEER_EDGE != 0 && edge_b)) begin
            if (reset_a) begin
                previous_a <= 1'b0;
                older_a <= 1'b0;
            end else begin
                previous_a <= x;
                older_a <= previous_a;
            end
        end
    end

    hold_a: assert property (@(posedge step_clock)
        !edge_a |=> x == $past(x));
    hold_b: assert property (@(posedge step_clock)
        !edge_b |=> y == $past(y));
    reset_on_a: assert property (@(posedge step_clock)
        (edge_a && reset_a) |=> ({x, previous_a, older_a} == 3'd0));
    reset_on_b: assert property (@(posedge step_clock)
        (edge_b && reset_b) |=> y == 1'b0);
    joint_prestate: assert property (@(posedge step_clock)
        (edge_a && edge_b && !reset_a && !reset_b)
        |=> (x == $past(y) && y == $past(x)));
    idle_history: assert property (@(posedge step_clock)
        !edge_a |=> ({previous_a, older_a} == $past({previous_a, older_a})));
    local_history: assert property (@(posedge step_clock)
        (edge_a && !reset_a) |=> (previous_a == $past(x) && older_a == $past(previous_a)));
    distinct_swap: cover property (@(posedge step_clock)
        (edge_a && edge_b && !reset_a && !reset_b && x != y)
        ##1 (x != y));
endmodule
