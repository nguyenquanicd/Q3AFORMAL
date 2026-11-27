module rtl_process_control_vectors (
    input  logic       enable,
    input  logic       select_a,
    input  logic       select_b,
    input  logic [3:0] data_a,
    input  logic [3:0] data_b,
    input  logic [3:0] data_c,
    input  logic [1:0] op,
    output logic [3:0] priority_y,
    output logic [3:0] case_y
);
    always_comb begin
        priority_y = 4'h0;
        if (enable) begin
            if (select_a) begin
                priority_y = data_a;
            end else if (select_b) begin
                priority_y = data_b;
            end else begin
                priority_y = data_c;
            end
        end else begin
            priority_y = 4'h0;
        end
    end

    always_comb begin
        case (op)
            2'b00:   case_y = 4'h1;
            2'b01:   case_y = 4'h2;
            2'b10:   case_y = 4'h4;
            default: case_y = 4'hF;
        endcase
    end
endmodule
