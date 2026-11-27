module casez_based_patterns (
    input  logic       clk,
    input  logic [6:0] sel,
    output logic [2:0] code
);
    always_comb begin
        casez (sel)
            7'hA?: code = 3'd0;
            7'O?5: code = 3'd1;
            7'h3:  code = 3'd2;
            7'b1?: code = 3'd3;
            7'h1_Z: code = 3'd4;
            default: code = 3'd5;
        endcase
    end

    property p_decode;
        @(posedge clk) (code ==
        (((sel & 7'h70) == 7'h20) ? 3'd0 :
        ((sel & 7'h07) == 7'h05) ? 3'd1 :
        (sel == 7'd3) ? 3'd2 :
        ((sel & 7'h7e) == 7'd2) ? 3'd3 :
        ((sel & 7'h70) == 7'h10) ? 3'd4 : 3'd5));
    endproperty
    property p_wrong;
        @(posedge clk) (sel == 7'h65) |-> (code == 3'd5);
    endproperty
    assert property (p_decode);
    assert property (p_wrong);
endmodule
