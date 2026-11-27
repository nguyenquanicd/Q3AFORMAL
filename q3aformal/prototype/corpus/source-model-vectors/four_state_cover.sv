module four_state_capture(input logic clk, input logic [1:0] data, output logic [1:0] captured);
    always_ff @(posedge clk) begin
        captured <= data;
    end

    p_history: assert property (@(posedge clk) captured === $past(data));
endmodule

module four_state_cover(input logic clk, input logic [1:0] data);
    logic [1:0] previous_data, window;
    assign window = data[data[0] +: 2];
    four_state_capture capture(.clk(clk), .data(data), .captured(previous_data));

    p_history: assert property (@(posedge clk) previous_data === $past(data));
    // The demo fails when the indexed slice extends above the declared vector.
    p_demo_counterexample: assert property (@(posedge clk)
        (data === 2'bz1) |-> (window === 2'bz1));
    c_xz_then_zx: cover property (@(posedge clk)
        (data === 2'bxz) |=> ((previous_data === 2'bxz) && (data === 2'bzx)));
endmodule
