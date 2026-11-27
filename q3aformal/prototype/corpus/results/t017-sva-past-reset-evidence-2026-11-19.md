# T017 SVA `$past` Warm-Up and Reset-Crossing Evidence

**Date:** 2026-11-19  
**Profile:** `Q3A-P0-R0.9.1`  
**Source:** `prototype/corpus/sva-vectors/sva_past_two_reset.sv`  
**Regression:** `prototype/tests/test_sva_history_frame_oracle.ps1`

## Source-to-T-IR evidence

The fixture contains explicit `$past(a)` and `$past(a, 2)` assertions, a synchronous reset on state `q`, and an assumption that keeps reset asserted at each sampled edge for bounded checks. The regression verifies both property predicates map to the expected history-data stages and source file; it checks the two-sample guard is initially invalid, valid after exactly two samples, and marked `retains_across_reset`.

## Independent sample-history oracle

A six-frame evaluator uses input samples `[1, 0, 1, 0, 1, 1]` and reset samples `[0, 1, 0, 1, 0, 0]`. It checks that stage 0 at frame `t` equals `a[t-1]`, stage 1 equals `a[t-2]`, and the guards become valid at frames 1 and 2. Both data stages and validity stages advance across asserted reset samples.

## BMC and replay evidence

- `$past(a)` at frame 0 yields `BOUNDED_PASS` with `VACUOUS`, because no prior sample exists. At frame 1 it can fail with a validated replayed witness while reset is asserted.
- `$past(a, 2)` through frame 1 yields `BOUNDED_PASS` with `VACUOUS`. At frame 2 it can fail non-vacuously; the bound is complete, reset is asserted, and the witness passes independent replay.

`test_sva_history_frame_oracle.ps1`, `test_sva_history_equations.ps1`, and `test_sva_delayed_past_implication.ps1` passed on 2026-11-19. Together they support SVA-009 and SVA-010 for the tested positive-edge, two-state profile with explicit one- and two-sample delays. They do not claim arbitrary unbounded history, multiple clocks, or full IEEE SystemVerilog Assertions semantics.
