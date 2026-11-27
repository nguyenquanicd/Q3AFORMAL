module p1_fifo_ring #(parameter WRONG_REPLACE = 0, parameter DATA_WIDTH = 4) (
    input  logic clk,
    input  logic rst,
    input  logic in_valid,
    input  logic [DATA_WIDTH-1:0] in_data,
    output logic in_ready,
    input  logic out_ready,
    output logic out_valid,
    output logic [DATA_WIDTH-1:0] front,
    output logic [DATA_WIDTH-1:0] second,
    output logic [1:0] occupancy,
    output logic read_pointer,
    output logic write_pointer
);
    logic [DATA_WIDTH-1:0] slot0, slot1;
    logic push, pop, write_slot;

    assign in_ready = (occupancy != 2'd2) || out_ready;
    assign out_valid = occupancy != 2'd0;
    assign front = read_pointer ? slot1 : slot0;
    assign second = read_pointer ? slot0 : slot1;
    assign push = in_valid && in_ready;
    assign pop = out_valid && out_ready;
    assign write_slot = (WRONG_REPLACE != 0 && occupancy == 2'd2 && pop)
        ? !write_pointer : write_pointer;

    always_ff @(posedge clk) begin
        if (rst) begin
            occupancy <= 2'd0;
            read_pointer <= 1'b0;
            write_pointer <= 1'b0;
            slot0 <= '0;
            slot1 <= '0;
        end else begin
            if (push) begin
                if (write_slot) slot1 <= in_data;
                else slot0 <= in_data;
                write_pointer <= !write_pointer;
            end
            if (pop) read_pointer <= !read_pointer;
            case ({push, pop})
                2'b10: occupancy <= occupancy + 2'd1;
                2'b01: occupancy <= occupancy - 2'd1;
                default: occupancy <= occupancy;
            endcase
        end
    end
endmodule

module p1_fifo_contract #(parameter WRONG_REPLACE = 0, parameter DATA_WIDTH = 4) (
    input logic clk,
    input logic rst,
    input logic in_valid,
    input logic [DATA_WIDTH-1:0] in_data,
    input logic out_ready
);
    logic in_ready, out_valid, read_pointer, write_pointer;
    logic [1:0] occupancy;
    logic [DATA_WIDTH-1:0] front, second;

    p1_fifo_ring #(.WRONG_REPLACE(WRONG_REPLACE), .DATA_WIDTH(DATA_WIDTH)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
        .out_ready(out_ready), .out_valid(out_valid), .front(front), .second(second),
        .occupancy(occupancy), .read_pointer(read_pointer), .write_pointer(write_pointer)
    );

    // Reference queue shifts its oldest item out, without circular pointers.
    logic head_valid, tail_valid;
    logic [DATA_WIDTH-1:0] head, tail;
    logic ref_ready, ref_push, ref_pop;
    assign ref_ready = !tail_valid || out_ready;
    assign ref_push = in_valid && ref_ready;
    assign ref_pop = head_valid && out_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            head_valid <= 1'b0;
            tail_valid <= 1'b0;
            head <= '0;
            tail <= '0;
        end else begin
            if (ref_pop && ref_push) begin
                if (tail_valid) begin
                    head <= tail;
                    tail <= in_data;
                end else head <= in_data;
            end else if (ref_pop) begin
                head_valid <= tail_valid;
                head <= tail;
                tail_valid <= 1'b0;
            end else if (ref_push) begin
                if (head_valid) begin
                    tail_valid <= 1'b1;
                    tail <= in_data;
                end else begin
                    head_valid <= 1'b1;
                    head <= in_data;
                end
            end
        end
    end

    logic related;
    assign related =
        ((occupancy == 2'd0 && !head_valid && !tail_valid) ||
         (occupancy == 2'd1 && head_valid && !tail_valid && front == head) ||
         (occupancy == 2'd2 && head_valid && tail_valid && front == head && second == tail)) &&
        ((read_pointer == write_pointer) == (occupancy != 2'd1));

    p_reset: assert property (@(posedge clk) rst |=> related);
    p_step: assert property (@(posedge clk) related |=> related);
    p_ports: assert property (@(posedge clk)
        related |-> (out_valid == head_valid && in_ready == ref_ready &&
                    (!head_valid || front == head)));

    p_full_replace: assert property (@(posedge clk)
        (rst ##1 (!rst && in_valid && !out_ready)
             ##1 (!rst && in_valid && !out_ready)
             ##1 (!rst && in_valid && out_ready && occupancy == 2'd2)) |=> related);
    c_full_replace_drain: cover property (@(posedge clk)
        rst ##1 (!rst && in_valid && !out_ready && in_data == 4'h3)
            ##1 (!rst && in_valid && !out_ready && in_data == 4'h9)
            ##1 (!rst && in_valid && out_ready && occupancy == 2'd2 && in_data == 4'hc)
            ##1 (!rst && !in_valid && out_ready && out_valid)
            ##1 (!rst && !in_valid && out_ready && out_valid)
            ##1 (!rst && !in_valid && !out_valid));
endmodule
