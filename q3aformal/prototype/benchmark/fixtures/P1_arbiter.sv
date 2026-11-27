module p1_arbiter (
    input logic clk,
    input logic rst,
    input logic [3:0] request,
    input logic accept,
    output logic [3:0] grant,
    output logic [3:0] last_grant
);
    logic [1:0] turn;
    always_comb begin
        case (turn)
            2'd0: grant = request[0] ? 4'b0001 : request[1] ? 4'b0010 : request[2] ? 4'b0100 : request[3] ? 4'b1000 : 4'b0000;
            2'd1: grant = request[1] ? 4'b0010 : request[2] ? 4'b0100 : request[3] ? 4'b1000 : request[0] ? 4'b0001 : 4'b0000;
            2'd2: grant = request[2] ? 4'b0100 : request[3] ? 4'b1000 : request[0] ? 4'b0001 : request[1] ? 4'b0010 : 4'b0000;
            default: grant = request[3] ? 4'b1000 : request[0] ? 4'b0001 : request[1] ? 4'b0010 : request[2] ? 4'b0100 : 4'b0000;
        endcase
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            turn <= 2'd0;
            last_grant <= 4'b0000;
        end else begin
            last_grant <= grant;
            if (accept && grant != 4'b0000) turn <= turn + 2'd1;
        end
    end
    p_registered_grant: assert property (@(posedge clk) $past(1'b1) |->
        (last_grant == 4'b0000 || last_grant == 4'b0001 || last_grant == 4'b0010 ||
         last_grant == 4'b0100 || last_grant == 4'b1000));
endmodule
