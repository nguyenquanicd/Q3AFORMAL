module parameter_localparam_vectors #(
    parameter integer WIDTH = 4
) (
    input  logic [WIDTH-1:0]       data_in,
    output logic [(WIDTH+WIDTH)-1:0] data_twice,
    output logic                   width_is_four
);
    localparam integer DOUBLE_WIDTH = WIDTH + WIDTH;

    assign data_twice    = {data_in, data_in};
    assign width_is_four = (WIDTH == 4);
endmodule
