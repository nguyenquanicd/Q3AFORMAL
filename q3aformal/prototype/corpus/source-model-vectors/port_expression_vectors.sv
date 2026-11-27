module four_bit_connection_leaf (
    input  logic [3:0] data_in,
    output logic [3:0] data_out
);
    assign data_out = data_in;
endmodule

module port_expression_top (
    input  logic [3:0] data_bus,
    output logic [3:0] concat_out,
    output logic [3:0] fill_out,
    output logic [3:0] literal_out
);
    four_bit_connection_leaf u_concat (
        .data_in({data_bus[3:2], data_bus[1:0]}),
        .data_out(concat_out)
    );
    four_bit_connection_leaf u_fill (
        .data_in('0),
        .data_out(fill_out)
    );
    four_bit_connection_leaf u_sized_literal (
        .data_in(4'hA),
        .data_out(literal_out)
    );
endmodule
