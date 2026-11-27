# Expected Results — rtl_process_control_vectors.sv

**Vector ID:** SM-009  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check complete-assignment always_comb, nested if/else priority, and exact case/default behavior.

## Expected equations

The priority output is:
- 0 when enable=0;
- data_a when enable=1 and select_a=1;
- data_b when enable=1, select_a=0, and select_b=1;
- data_c when enable=1 and both select_a and select_b are 0.

When select_a and select_b are both 1, the first branch wins and priority_y=data_a.

The exact case output is:
- op=00 -> case_y=1;
- op=01 -> case_y=2;
- op=10 -> case_y=4;
- op=11 -> case_y=F through default.

## Expected elaborated/T-IR properties

- Both always_comb blocks assign their output on every control path; no latch state is introduced.
- The nested if/else becomes a priority mux with select_a before select_b.
- The case selector is a two-bit value and each item is an exact match; the default handles the remaining value.
- The processes are combinational equations evaluated from the same sampled inputs; no clock or state is created.

## Review boundary

The negative incomplete-assignment/latch example is RTL-021 and must be rejected before T-IR generation. This source is the positive complete-assignment counterpart.

