module casez_decode (
    input  logic [3:0] sel,
    output logic [1:0] code
);
    always_comb begin
        code = 2'b00;
        casez (sel)
            4'b1???: code = 2'b01;
            4'b10??: code = 2'b10;
            default: code = 2'b00;
        endcase
    end
endmodule
