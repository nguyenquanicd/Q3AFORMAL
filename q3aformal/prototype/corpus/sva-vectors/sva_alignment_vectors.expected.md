# Expected Results — sva_alignment_vectors.sv

**Vector ID:** SVV-004  
**Profile:** Q3A-P0-R0.9.1

The first two properties use the antecedent `a ##1 b` and consequent `c ##2 d`.

- For `|->`, if `a` matches at sample `t` and `b` at `t+1`, the consequent starts at the antecedent end: `c` is required at `t+1`, and `d` at `t+3`.
- For `|=>`, the consequent starts one sample after the antecedent end: `c` is required at `t+2`, and `d` at `t+4`.

`p_zero_delay_chain` uses `(a ##0 b) |-> c`; `a`, `b`, and `c` are all sampled at the same frame. Together, these vectors check fixed sequence delays `##0`, `##1`, and `##2` in T-IR and in the independent frame oracle.

The bounded property `a[*1:3] |=> b` permits every consecutive match length from one through three. Each antecedent match end launches a separate next-sample `b` obligation. When `a` is high at samples 0, 1, and 2, matches of lengths 1/2/3 end at 0/1/2; the required `b` samples are therefore 1, 2, and 3.

The exact-count properties `a[*1] |=> b`, `a[*2] |=> b`, and `a[*3] |=> b` check multiple positive counts. The equal-bound range `a[*2:2] |=> b` is semantically identical to `a[*2] |=> b`: both require exactly two consecutive `a` samples and then `b` at the next sample. The two count-2 forms must lower to identical repeat bounds (`repeat_min=2`, `repeat_max=2`) and produce the same pass/fail result for the same trace.

`test_sva_sequence_alignment_oracle.ps1` checks the lowered term delays/repetition bounds and evaluates passing/failing traces against these independently specified sample alignments. It verifies a focused sequence subset; it is not a property proof engine or full IEEE 1800 conformance result.
