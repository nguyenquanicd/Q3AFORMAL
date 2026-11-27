module sequential_case_vectors (
    input  logic       clk,
    input  logic [1:0] select,
    input  logic       value_a,
    input  logic       value_b,
    output logic       result
);
    always_ff @(posedge clk) begin
        case (select)
            2'b00: begin
                result <= value_a;
                result <= value_b;
            end
            2'b01, 2'b10: result <= value_a;
            default: result <= result;
        endcase
    end
endmodule
