# SVA Conformance Vectors

These examples define expected profile behavior; they are not execution results.

| ID | Form | Expected behavior |
|---|---|---|
| SVA-001 | @(posedge clk) assert property (count <= 4'hF) | Sample count before the transition; property is true for a 4-bit vector. |
| SVA-002 | @(posedge clk) (count == 4'hF) |=> (count == 4'h0) | Consequent is checked at the next positive-edge sample. |
| SVA-003 | @(posedge clk) (a) |-> (b) | Consequent begins at the sample where antecedent ends. |
| SVA-004 | a ##0 b | Both sequence terms use the same sampled cycle, subject to the supported sequence grammar. |
| SVA-005 | a ##2 b | b is sampled two clock cycles after the end sample of a. |
| SVA-006 | a[*3] | Match exactly three consecutive sequence matches. |
| SVA-007 | a[*1:3] | Match one, two, or three consecutive sequence matches. |
| SVA-008 | $past(data) | Uses the prior sampled value after the generated one-cycle history-valid guard is true; the first sample is suppressed. |
| SVA-009 | $past(data, 2) | Uses the value from two sampled edges earlier after two samples have been captured. |
| SVA-010 | $past(data, 0) | Reject because N must be positive in this profile. |
| NEG-SVA-001 | a[*0] or a[*0:2] | Reject exact zero-count and zero-minimum repetition; empty-sequence cases are outside Phase 0. |
| SVA-011 | disable iff (!rst) | Reject before proof; do not reinterpret synchronously. |
| SVA-012 | @(posedge clk_a) ... @(posedge clk_b) | Reject as multi-clock. |
| SVA-013 | a[*1:$] | Reject as unbounded repetition. |
| SVA-014 | a[->2] or a[=2] | Reject goto and nonconsecutive repetition. |
| SVA-015 | $stable(data), $rose(signal), $fell(signal), $changed(signal) | Reject these sampled-value functions in Phase 0. |
| SVA-016 | assume property (x) and assume property (!x) at same sample | Detect frame-local contradiction when the exact query proves inconsistency. |
| SVA-017 | cover property (req ##1 ack) with a bounded search miss | Return no complete UNREACHABLE conclusion from a bounded miss. |

## History guard convention

For a property containing one or more $past calls, Q3A generates a history-valid state for the maximum requested delay. The state begins false, becomes true after the required number of sampled clock edges, and is not reset by the RTL reset. The property is evaluated only when this state is true. The warm-up restriction is part of the selected profile and is recorded in every result.

## Terminology

| Abbreviation | Meaning |
|---|---|
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |

## Source vector SVV-001 — sva_sequence_vectors.sv

This source file provides profile inputs for both implication operators, ##0/1/2, positive exact and bounded consecutive repetition, guarded $past delays 1 and 2, assertion/assumption/cover declarations, and one positive-edge clock. Expected sample alignment and model behavior are in sva_sequence_vectors.expected.md. Exact zero-count and zero-minimum repetition are rejected in profile Q3A-P0-R0.9.1; see sva_zero_repetition_reject.sv.

## Source vector SVV-002 — sva_parameter_bounds.sv

This source checks compile-time parameter resolution for sequence delays and repetition counts. `lower-sva-parameter-bounds.q3a` overrides `DELAY` to 3 and `REPEAT_COUNT` to 4; the symbolic automaton transitions retain delay 3 and exact repetition 4. `test_sva_sequence_alignment_oracle.ps1` checks these resolved bounds along with frame alignment.

## Source vector SVV-003 — sva_nested_past.sv

This source checks nested `$past($past(a))`. Its history data is represented by two successive sampled-value state stages, so the property guard must remain invalid until two clock samples have been captured. See sva_nested_past.expected.md and `test_sva_history_frame_oracle.ps1` for the independent six-frame shift check and reset-crossing validity check. These are focused T017 evidence, not complete SVA conformance.

## Source vector SVV-004 — sva_alignment_vectors.sv

This source checks overlapped and non-overlapped implication alignment, delayed terms, and positive bounded repetition for bounded queries. It also contains multi-term sequences that remain outside the induction subset.

This source checks fixed `##0`/`##1`/`##2` offsets, multi-term `|->`/`|=>` sample alignment, and bounded repetition in an antecedent. See `sva_alignment_vectors.expected.md` and `test_sva_sequence_alignment_oracle.ps1` for the independent frame oracle covering pass/fail traces and each antecedent match end. The same vector now checks exact repeat counts 1/2/3, the equal-bound range 2:2 against an exact count of 2, and a source-level ##0 BMC counterexample validated by replay.

## Source vector SVV-005 — sva_induction_implications.sv

See `sva_induction_implications.expected.md`. The one-term, `##0`, fixed/bounded-repetition scalar-sequence, variable-repetition, non-overlapped, `sva-induction-delayed-assumptions.q3a`, and `sva-induction-delayed-guarded-assumption.q3a` manifests plus `test_inductive_sva_implication.ps1` check scalar and same-sample overlapped/non-overlapped assertion/assumption induction, fixed and variable repeated/delayed standalone sequence assertions, bounded delayed/repeated assertion implication operands and assumptions, independently checked proof artifacts, replayed reachable failures, and a stateful guarded-`$past` invariant. Delayed scalar or implication assertions and assumptions with guarded `$past`, unbounded delay ranges and automata with more than 4096 match paths remain rejected. Bounded delayed assumptions are exercised through complete-window proofs and independently replayed failures. The range regression also covers ##[0:1], ##[1:2], ##[2:2], parameterized bounds, |->, |=>, consequent matching, assumptions, BMC, and replay.



## SVV-006 — explicit `$past` history across reset

See `sva_past_two_reset.sv` and `sva_past_two_reset.expected.md`. The vector exercises default `$past(a)` and explicit `$past(a, 2)` with a synchronous reset and reset-held assumption; `test_sva_history_frame_oracle.ps1` checks sampled history, guard warm-up, source mapping, and replay-validated failures at the first valid frames.

## Source vector SVV-007 — sva_assertion_conformance.sv

See sva_assertion_conformance.expected.md and [SVA-001/SVA-002 evidence](../results/t017-sva001-002-assertion-clock-2026-11-20.md). The regression checks one posedge clock, source-mapped known-true/known-false concurrent assertions, a frame-0 replayed failure, and rejection of negedge before BMC.

## Source vector SVV-008 — sva_assumption_conformance.sv

See sva_assumption_conformance.expected.md and [SVA-003 evidence](../results/t017-sva003-assumption-frames-2026-11-20.md). The independent oracle checks all eight three-frame input sequences under a consistent assumption and both values under contradictory assumptions; BMC checks nonvacuous pass and INCONSISTENT_MODEL_OR_ASSUMPTIONS.