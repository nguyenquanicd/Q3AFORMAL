module bmc_casez_replay_top (
    input logic clk,
    input logic [1:0] sel,
    output logic [3:0] out
);
    always_comb begin
        casez (sel)
            2'b1?: out = 4'hA;
            default: out = 4'h5;
        endcase
    end

    property p_output_is_zero;
        @(posedge clk) out == 4'h0;
    endproperty

    assert property (p_output_is_zero);
endmodule
