module pdr_pipeline6(input logic clk, input logic a, input logic [7:0] data);
    logic q1, q2, q3, q4, q5, q6;
    logic [7:0] data_q1, data_q2;

    always_ff @(posedge clk) begin
        q1 <= a;
        q2 <= q1;
        q3 <= q2;
        q4 <= q3;
        q5 <= q4;
        q6 <= q5;
        data_q1 <= data;
        data_q2 <= data_q1;
    end

    p_latency: assert property (@(posedge clk) q6 == $past(a, 6));
    p_mutation: assert property (@(posedge clk) q6 != $past(a, 6));
endmodule
