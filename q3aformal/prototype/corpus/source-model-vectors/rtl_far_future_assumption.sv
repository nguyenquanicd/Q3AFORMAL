module rtl_far_future_assumption (
    input logic clk,
    input logic request,
    input logic grant
);
    localparam MAX_DELAY = 64'hffff_ffff_ffff_ffff;

    property env_future; @(posedge clk)
        request |=> (request ##MAX_DELAY grant);
    endproperty
    property p_grant; @(posedge clk)
        grant;
    endproperty
    assume property (env_future);
    assert property (p_grant);
endmodule
