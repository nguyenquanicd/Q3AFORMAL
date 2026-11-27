module casez_decode_bench (
    input  logic       clk,
    input  logic [3:0] sel,
    output logic [1:0] code
);
    always_comb begin
        casez (sel)
            4'b1???: code = 2'b01;
            4'b10??: code = 2'b10;
            default: code = 2'b00;
        endcase
    end

    property p_casez_decode_matches_priority;
        @(posedge clk) code == (sel[3] ? 2'b01 : 2'b00);
    endproperty

    assert property (p_casez_decode_matches_priority);
endmodule
