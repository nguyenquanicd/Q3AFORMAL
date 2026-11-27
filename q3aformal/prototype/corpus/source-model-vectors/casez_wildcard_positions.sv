module casez_wildcard_positions (
    input  logic [3:0] sel,
    output logic [1:0] code
);
    always_comb begin
        casez (sel)
            4'b?1??: code = 2'b00;
            4'b??1?: code = 2'b01;
            4'b???1: code = 2'b10;
            default: code = 2'b11;
        endcase
    end
endmodule
