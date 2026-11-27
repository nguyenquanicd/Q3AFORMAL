module nonterminating_generate_reject (
    output logic y
);
    generate
        for (genvar i = 0; i < 1; i = i) begin : g_stuck
            assign y = 1'b0;
        end
    endgenerate
endmodule
