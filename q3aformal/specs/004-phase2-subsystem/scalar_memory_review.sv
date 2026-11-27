module scalar_memory_review #(
    parameter CHECK_RANGE = 1,
    parameter WRITE_FIRST = 0
) (
    input logic clk,
    input logic read_request, write_request,
    input logic [1:0] read_address, write_address, write_data,
    output logic [1:0] read_data
);
    // This fixture encodes the proposed memory transition using scalar state.
    logic [1:0] word0, word1, word2;
    logic read_enable, write_enable, collision;
    logic [1:0] read_before_write;
    logic [5:0] expected_words;

    assign read_enable = read_request && (CHECK_RANGE == 0 || read_address != 2'd3);
    assign write_enable = write_request && (CHECK_RANGE == 0 || write_address != 2'd3);
    assign collision = write_enable && (read_address == write_address);
    assign read_before_write = (read_address == 2'd0) ? word0 :
                               (read_address == 2'd1) ? word1 : word2;
    assign expected_words = {
        (write_enable && write_address == 2'd2) ? write_data : word2,
        (write_enable && write_address == 2'd1) ? write_data : word1,
        (write_enable && write_address == 2'd0) ? write_data : word0
    };

    always_ff @(posedge clk) begin
        if (write_enable) begin
            case (write_address)
                2'd0: word0 <= write_data;
                2'd1: word1 <= write_data;
                2'd2: word2 <= write_data;
            endcase
        end
        if (read_enable) begin
            if ((WRITE_FIRST != 0) && collision) read_data <= write_data;
            else begin
                case (read_address)
                    2'd0: read_data <= word0;
                    2'd1: read_data <= word1;
                    2'd2: read_data <= word2;
                endcase
            end
        end
    end

    read_in_range: assert property (@(posedge clk)
        !read_enable || read_address != 2'd3);
    write_in_range: assert property (@(posedge clk)
        !write_enable || write_address != 2'd3);
    read_old: assert property (@(posedge clk)
        (read_enable && read_address != 2'd3) |=> read_data == $past(read_before_write));
    disabled_read_holds: assert property (@(posedge clk)
        !read_enable |=> read_data == $past(read_data));
    single_cell_update: assert property (@(posedge clk)
        1'b1 |=> {word2, word1, word0} == $past(expected_words));
    distinct_collision: cover property (@(posedge clk)
        read_enable && collision && read_before_write != write_data);
endmodule
