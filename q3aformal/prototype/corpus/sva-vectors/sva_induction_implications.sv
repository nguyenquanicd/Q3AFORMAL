module sva_induction_implication_top (
    input  logic clk,
    input  logic a,
    input  logic b,
    output logic y
);
    assign y = a && b;

    property p_y_implies_a;
        @(posedge clk) y |-> a;
    endproperty
    assert property (p_y_implies_a);

    property p_false_implication;
        @(posedge clk) a |-> b;
    endproperty
    assert property (p_false_implication);
endmodule

module sva_induction_implication_assumption_top (
    input logic clk,
    input logic a,
    input logic b
);
    property p_environment;
        @(posedge clk) a |-> b;
    endproperty
    assume property (p_environment);

    property p_assumption_consequence;
        @(posedge clk) a |-> b;
    endproperty
    assert property (p_assumption_consequence);
endmodule

module sva_induction_overlapped_past_top (
    input  logic clk,
    input  logic a,
    output logic q
);
    always_ff @(posedge clk) begin
        q <= a;
    end

    property p_q_tracks_past;
        @(posedge clk) q |-> $past(a);
    endproperty
    assert property (p_q_tracks_past);
endmodule

module sva_induction_zero_delay_top (
    input  logic clk,
    input  logic a,
    input  logic b,
    input  logic c,
    input  logic d,
    output logic y
);
    assign y = a && b;

    property p_y_pair_implies_pair;
        @(posedge clk) (y ##0 a) |-> (a ##0 b);
    endproperty
    assert property (p_y_pair_implies_pair);

    property p_false_zero_delay;
        @(posedge clk) (a ##0 b) |-> (c ##0 d);
    endproperty
    assert property (p_false_zero_delay);

    property p_scalar_zero_delay_pair;
        @(posedge clk) (a ##0 b);
    endproperty
    assert property (p_scalar_zero_delay_pair);

    property p_scalar_zero_delay_true;
        @(posedge clk) (1'b1 ##0 1'b1);
    endproperty
    assert property (p_scalar_zero_delay_true);
endmodule

module sva_induction_zero_delay_assumption_top (
    input logic clk,
    input logic a,
    input logic b,
    input logic c,
    input logic d
);
    property p_environment_pair;
        @(posedge clk) (a ##0 b) |-> (c ##0 d);
    endproperty
    assume property (p_environment_pair);

    property p_environment_scalar_pair;
        @(posedge clk) (c ##0 d);
    endproperty
    assume property (p_environment_scalar_pair);

    property p_assumption_pair_consequence;
        @(posedge clk) (a ##0 b) |-> (c ##0 d);
    endproperty
    assert property (p_assumption_pair_consequence);

    property p_scalar_assumption_consequence;
        @(posedge clk) (c ##0 d);
    endproperty
    assert property (p_scalar_assumption_consequence);

    property p_false_under_zero_delay_assumption;
        @(posedge clk) a |-> !a;
    endproperty
    assert property (p_false_under_zero_delay_assumption);
endmodule

module sva_induction_nonoverlapped_top (
    input  logic clk,
    input  logic a,
    input  logic b,
    output logic q
);
    always_ff @(posedge clk) begin
        q <= a && b;
    end

    property p_pair_implies_next_q;
        @(posedge clk) (a ##0 b) |=> (q ##0 q);
    endproperty
    assert property (p_pair_implies_next_q);

    property p_false_next_input;
        @(posedge clk) a |=> b;
    endproperty
    assert property (p_false_next_input);
endmodule

module sva_induction_nonoverlapped_assumption_top (
    input logic clk,
    input logic a,
    input logic b
);
    property p_environment_next;
        @(posedge clk) a |=> b;
    endproperty
    assume property (p_environment_next);

    property p_target_next;
        @(posedge clk) a |=> b;
    endproperty
    assert property (p_target_next);

    property p_false_target_under_next_assumption;
        @(posedge clk) a |=> !a;
    endproperty
    assert property (p_false_target_under_next_assumption);
endmodule

module sva_induction_nonoverlapped_past_top (
    input  logic clk,
    input  logic a
);
    property p_next_past;
        @(posedge clk) a |=> $past(a);
    endproperty
    assert property (p_next_past);
endmodule

module sva_induction_delay_one_top (
    input  logic clk,
    input  logic a,
    input  logic b,
    output logic q
);
    always_ff @(posedge clk) begin
        q <= a;
    end

    property p_constant_delayed_sequence;
        @(posedge clk) 1'b1[*2] ##2 1'b1[*2];
    endproperty
    assert property (p_constant_delayed_sequence);

    property p_constant_one_delay;
        @(posedge clk) 1'b1 ##1 1'b1;
    endproperty
    assert property (p_constant_one_delay);

    property p_false_delayed_sequence;
        @(posedge clk) a[*2] ##2 b[*2];
    endproperty
    assert property (p_false_delayed_sequence);

endmodule

module sva_induction_variable_repeat_top (
    input  logic clk,
    input  logic a,
    input  logic b,
    input  logic c,
    input  logic d,
    output logic q
);
    always_ff @(posedge clk) begin
        q <= ~q;
    end

    property p_any_repeat_path_matches_q;
        @(posedge clk) 1'b1[*1:2] ##1 q;
    endproperty
    assert property (p_any_repeat_path_matches_q);

    property p_false_variable_repetition;
        @(posedge clk) a[*1:2];
    endproperty
    assert property (p_false_variable_repetition);

    property p_delayed_overlapped_implication;
        @(posedge clk) 1'b1[*1:2] ##1 q |-> q;
    endproperty
    assert property (p_delayed_overlapped_implication);

    property p_delayed_nonoverlapped_implication;
        @(posedge clk) 1'b1[*1:2] ##1 q |=> !q;
    endproperty
    assert property (p_delayed_nonoverlapped_implication);

    property p_false_delayed_implication;
        @(posedge clk) (a ##1 b) |-> (c ##2 d);
    endproperty
    assert property (p_false_delayed_implication);
endmodule

module sva_induction_delayed_assumption_top (
    input logic clk,
    input logic a,
    input logic b,
    input logic c,
    input logic d,
    input logic t
);
    property p_environment_sequence;
        @(posedge clk) a ##1 b;
    endproperty
    assume property (p_environment_sequence);

    property p_environment_implication;
        @(posedge clk) (a ##1 b) |-> (c ##1 d);
    endproperty
    assume property (p_environment_implication);

    property p_sequence_target;
        @(posedge clk) a ##1 b;
    endproperty
    assert property (p_sequence_target);

    property p_implication_target;
        @(posedge clk) (a ##1 b) |-> (c ##1 d);
    endproperty
    assert property (p_implication_target);

    property p_false_target_under_delayed_assumptions;
        @(posedge clk) (a ##1 b) |-> (c ##1 (d && t));
    endproperty
    assert property (p_false_target_under_delayed_assumptions);
endmodule

module sva_induction_delayed_guarded_assumption_top (
    input logic clk,
    input logic a,
    input logic b
);
    property p_delayed_guarded_environment;
        @(posedge clk) $past(a) ##1 b;
    endproperty
    assume property (p_delayed_guarded_environment);

    property p_target;
        @(posedge clk) a;
    endproperty
    assert property (p_target);
endmodule

module sva_induction_variable_delay_top #(
    parameter integer DELAY_MIN = 1,
    parameter integer DELAY_MAX = 2
) (
    input logic clk,
    input logic a,
    input logic b,
    input logic c,
    input logic d,
    output logic q
);
    always_ff @(posedge clk) begin
        q <= ~q;
    end

    property p_delay_1_to_2_matches_q;
        @(posedge clk) 1'b1 ##[1:2] q;
    endproperty
    assert property (p_delay_1_to_2_matches_q);

    property p_delay_0_to_1_matches_q;
        @(posedge clk) 1'b1 ##[0:1] q;
    endproperty
    assert property (p_delay_0_to_1_matches_q);

    property p_exact_delay_range;
        @(posedge clk) 1'b1 ##[2:2] 1'b1;
    endproperty
    assert property (p_exact_delay_range);

    property p_parameterized_delay_range;
        @(posedge clk) 1'b1 ##[DELAY_MIN:DELAY_MAX] q;
    endproperty
    assert property (p_parameterized_delay_range);

    property p_range_overlapped_implication;
        @(posedge clk) (1'b1 ##[1:2] q) |-> q;
    endproperty
    assert property (p_range_overlapped_implication);

    property p_range_nonoverlapped_implication;
        @(posedge clk) (1'b1 ##[1:2] q) |=> !q;
    endproperty
    assert property (p_range_nonoverlapped_implication);

    property p_range_in_consequent;
        @(posedge clk) (1'b1 ##[1:2] q) |-> (q ##[0:1] !q);
    endproperty
    assert property (p_range_in_consequent);

    property p_false_variable_delay;
        @(posedge clk) a ##[1:2] b;
    endproperty
    assert property (p_false_variable_delay);

endmodule

module sva_induction_variable_delay_assumption_top (
    input logic clk,
    input logic a,
    input logic b,
    input logic c,
    input logic d,
    input logic t
);
    property p_environment_delay_range;
        @(posedge clk) a ##[1:2] b;
    endproperty
    assume property (p_environment_delay_range);

    property p_environment_implication_delay_range;
        @(posedge clk) (a ##[1:2] b) |-> (c ##[0:1] d);
    endproperty
    assume property (p_environment_implication_delay_range);

    property p_sequence_target;
        @(posedge clk) a ##[1:2] b;
    endproperty
    assert property (p_sequence_target);

    property p_implication_target;
        @(posedge clk) (a ##[1:2] b) |-> (c ##[0:1] d);
    endproperty
    assert property (p_implication_target);

    property p_false_target_under_delay_assumptions;
        @(posedge clk) (a ##[1:2] b) |-> (c ##[0:1] (d && t));
    endproperty
    assert property (p_false_target_under_delay_assumptions);
endmodule
