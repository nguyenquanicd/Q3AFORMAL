module width_child (
    input  logic [7:0] data_in,
    output logic [7:0] data_out
);
    assign data_out = data_in;
endmodule

module port_width_mismatch_reject (
    input  logic [3:0] narrow_data,
    output logic [7:0] result
);
    width_child u_width_child (
        .data_in(narrow_data),
        .data_out(result)
    );
endmodule
