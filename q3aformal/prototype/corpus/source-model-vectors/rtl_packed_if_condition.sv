module rtl_packed_if_condition (
    input logic clk,
    input logic [63:0] reset_bits,
    input logic signed [2:0] data,
    output logic selected,
    output logic captured
);
    always_comb begin
        if (data + 3'sd1)
            selected = 1'b1;
        else
            selected = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (reset_bits)
            captured <= 1'b0;
        else if (data)
            captured <= 1'b1;
        else
            captured <= 1'b0;
    end

    property p_wrap;
        @(posedge clk) (selected == (data != 3'sb111));
    endproperty
    property p_capture;
        @(posedge clk) 1'b1 |=> (captured ==
            (($past(reset_bits) == 64'd0) && ($past(data) != 3'sd0)));
    endproperty
    property p_wrong;
        @(posedge clk) ((reset_bits == 64'h8000000000000000) && (data == 3'sd1))
            |=> captured;
    endproperty
    assert property (p_wrap);
    assert property (p_capture);
    assert property (p_wrong);
endmodule
