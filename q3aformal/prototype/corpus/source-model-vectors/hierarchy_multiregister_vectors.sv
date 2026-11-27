module hierarchy_pair_leaf (
    input  logic clk,
    input  logic rst,
    input  logic new_a,
    output logic out_a,
    output logic out_b
);
    logic a_q;
    logic b_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_q <= 1'b0;
            b_q <= 1'b0;
        end else begin
            a_q <= new_a;
            b_q <= a_q;
        end
    end

    assign out_a = a_q;
    assign out_b = b_q;
endmodule

module hierarchy_pair_top (
    input  logic clk,
    input  logic rst,
    input  logic new_a,
    output logic out_a,
    output logic out_b
);
    hierarchy_pair_leaf u_pair (
        .clk(clk),
        .rst(rst),
        .new_a(new_a),
        .out_a(out_a),
        .out_b(out_b)
    );
endmodule
