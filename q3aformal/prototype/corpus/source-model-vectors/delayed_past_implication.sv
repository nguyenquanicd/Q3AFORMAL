module delayed_past_implication_top (
    input logic clk,
    input logic antecedent,
    input logic sampled_value
);
    property p_delayed_consequent_past_fails;
        @(posedge clk) antecedent |-> 1'b1 ##1 !$past(sampled_value);
    endproperty

    property c_delayed_consequent_past_hits;
        @(posedge clk) antecedent |-> 1'b1 ##1 $past(sampled_value);
    endproperty

    property p_immediate_consequent_past_fails;
        @(posedge clk) antecedent |-> !$past(sampled_value);
    endproperty

    property c_immediate_consequent_past_hits;
        @(posedge clk) antecedent |-> $past(sampled_value);
    endproperty

    property p_delayed_antecedent_past_fails;
        @(posedge clk) 1'b1 ##1 $past(sampled_value) |-> 1'b0;
    endproperty

    property c_delayed_antecedent_past_hits;
        @(posedge clk) 1'b1 ##1 $past(sampled_value);
    endproperty

    property p_immediate_antecedent_past_fails;
        @(posedge clk) $past(sampled_value) |-> 1'b0;
    endproperty

    assert property (p_delayed_consequent_past_fails);
    cover property (c_delayed_consequent_past_hits);
    assert property (p_immediate_consequent_past_fails);
    cover property (c_immediate_consequent_past_hits);
    assert property (p_delayed_antecedent_past_fails);
    cover property (c_delayed_antecedent_past_hits);
    assert property (p_immediate_antecedent_past_fails);
endmodule
