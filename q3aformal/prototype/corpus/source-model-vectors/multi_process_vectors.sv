module multi_process_top (
    input  logic clk,
    input  logic rst,
    input  logic new_a,
    output logic a_q,
    output logic b_q
);
    always_ff @(posedge clk) begin
        if (rst) begin
            a_q <= 1'b0;
        end else begin
            a_q <= new_a;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            b_q <= 1'b0;
        end else begin
            b_q <= a_q;
        end
    end
endmodule
