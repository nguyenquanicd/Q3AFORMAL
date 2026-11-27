module case_comparison_context (
    input logic clk,
    input logic signed [2:0] sel,
    input logic [2:0] data,
    output logic signed_match, mixed_match, widened_sum, fill_match, constant_sum,
    output logic sequential_match
);
    logic [2:0] saved;
    always_comb begin
        case (sel)
            5'sb11111: signed_match = 1'b1;
            default:   signed_match = 1'b0;
        endcase
        case (sel)
            5'sb11111: mixed_match = 1'b0;
            3'sb111:   mixed_match = 1'b1;
            5'd0:      mixed_match = 1'b0;
            default:   mixed_match = 1'b0;
        endcase
        saved = data + 3'd1;
        case (saved + 3'd1)
            4'd8: widened_sum = 1'b1;
            default: widened_sum = 1'b0;
        endcase
        case (data)
            '1:   fill_match = 1'b1;
            5'd0: fill_match = 1'b0;
            default: fill_match = 1'b0;
        endcase
        case ({1'b1, data})
            (3'd7 + 3'd1): constant_sum = 1'b1;
            default: constant_sum = 1'b0;
        endcase
    end
    always_ff @(posedge clk) begin
        case (data + 3'd1)
            4'd8: sequential_match <= 1'b1;
            default: sequential_match <= 1'b0;
        endcase
    end
    property p_context;
        @(posedge clk) ((signed_match == (sel == 3'sb111)) &&
            (mixed_match == (sel == 3'sb111)) &&
            (widened_sum == (data == 3'd6)) && (fill_match == 1'b0) &&
            (constant_sum == (data == 3'd0)));
    endproperty
    property p_sequential;
        @(posedge clk) (data == 3'd7) |=> sequential_match;
    endproperty
    property p_wrong;
        @(posedge clk) (data == 3'd7) |=> !sequential_match;
    endproperty
    assert property (p_context);
    assert property (p_sequential);
    assert property (p_wrong);
endmodule
