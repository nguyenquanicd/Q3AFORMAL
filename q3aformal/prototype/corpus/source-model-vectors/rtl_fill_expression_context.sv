module rtl_fill_expression_context (
    input logic clk,
    input logic sel,
    input logic [7:0] x
);
    logic [15:0] masked;
    logic [7:0] packed_bits;
    logic [15:0] shifted;
    logic [15:0] selected;
    logic [7:0] from_child;
    logic [7:0] tied_child;
    logic hit;
    logic [63:0] registered_fill;

    assign masked = x & '1;
    assign packed_bits = {'1, x[5:0], '0};
    assign shifted = 16'd1 << '1;
    assign selected = sel ? '1 : (x & '0);
    fill_expression_child u_child(.data(x << '1), .value(from_child));
    fill_expression_child u_tied(.data(sel ? '1 : '0), .value(tied_child));
    always_comb begin
        case (x)
            '1: hit = 1'b1;
            default: hit = 1'b0;
        endcase
    end
    always_ff @(posedge clk) begin
        registered_fill <= sel ? '1 : '0;
    end

    property p_compare; @(posedge clk)
        (x == '1) == (x == 8'hff);
    endproperty
    property p_mask; @(posedge clk)
        masked == {8'h00, x};
    endproperty
    property p_packed; @(posedge clk)
        packed_bits == {1'b1, x[5:0], 1'b0};
    endproperty
    property p_shift; @(posedge clk)
        shifted == 16'd2;
    endproperty
    property p_selected; @(posedge clk)
        (sel && selected == 16'hffff) || (!sel && selected == 16'h0000);
    endproperty
    property p_child; @(posedge clk)
        from_child == {x[6:0], 1'b0};
    endproperty
    property p_tied_child; @(posedge clk)
        (sel && tied_child == 8'hff) || (!sel && tied_child == 8'h00);
    endproperty
    property p_bad_mask; @(posedge clk)
        masked == {15'h0000, x[0]};
    endproperty
    property p_case; @(posedge clk)
        hit == (x == 8'hff);
    endproperty
    property p_register; @(posedge clk)
        sel |=> registered_fill == 64'hffff_ffff_ffff_ffff;
    endproperty
    property p_register_zero; @(posedge clk)
        !sel |=> registered_fill == 64'h0;
    endproperty

    assert property(p_compare);
    assert property(p_mask);
    assert property(p_packed);
    assert property(p_shift);
    assert property(p_selected);
    assert property(p_child);
    assert property(p_tied_child);
    assert property(p_bad_mask);
    assert property(p_case);
    assert property(p_register);
    assert property(p_register_zero);
endmodule

module fill_expression_child(input logic [7:0] data, output logic [7:0] value);
    assign value = data;
endmodule
