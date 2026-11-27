module case_order_vectors (
    input  logic [1:0] select,
    output logic [1:0] result
);
    always_comb begin
        case (select)
            2'b00:   result = 2'b00;
            2'b01:   result = 2'b01;
            2'b01:   result = 2'b10;
            default: result = 2'b11;
        endcase
    end
endmodule
