module pdr_cone_environment(input logic clk, input logic req, input logic [15:0] data);
    logic off1, off2;
    logic can_request;
    logic [15:0] unrelated;

    assign can_request = off2;
    always_ff @(posedge clk) begin
        off1 <= 1'b0;
        off2 <= off1;
        unrelated <= data;
    end

    env_request: assume property (@(posedge clk) req |-> can_request);
    p_quiet: assert property (@(posedge clk) ($past(req, 2) || !$past(req, 2)) && !req);
    p_mutation: assert property (@(posedge clk) ($past(req, 2) || !$past(req, 2)) && req);
    c_late: cover property (@(posedge clk) $past(req, 2) && !req);
endmodule
