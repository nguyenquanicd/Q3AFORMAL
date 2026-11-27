# T017 SVA Implication and Repetition Alignment Evidence

**Date:** 2026-11-19  
**Profile:** `Q3A-P0-R0.9.1`  
**Regression:** `prototype/tests/test_sva_sequence_alignment_oracle.ps1`

## Source-to-T-IR checks

The source vector `prototype/corpus/sva-vectors/sva_alignment_vectors.sv` contains fixed delays `##0`, `##1`, and `##2`, two-term antecedents and consequents for both `|->` and `|=>`, exact consecutive repetition counts 1, 2, and 3, bounded repetition `[*1:3]`, and an equal-bound range `[*2:2]`. The regression checks sequence terms and automaton transitions against the emitted T-IR, including `repeat_min`/`repeat_max`.

## Independent frame oracle

The separate PowerShell frame evaluator verifies:

- For `a ##1 b`, overlapped implication starts the consequent at the antecedent end; non-overlapped implication starts one sample later.
- For `(a ##0 b) |-> c`, all three predicates are sampled in the same frame; pass/fail traces check that a missing same-frame `c` fails.
- The `##2` consequent in the two-term chain is checked at the specified later frame, alongside the `##1` antecedent transition.
- An end-to-end `--bmc` run for the zero-delay property produces a non-vacuous frame-0 counterexample with `a=1`, `b=1`, and `c=0`; the transition bound is complete and independent replay validates the witness.
- For `a[*1:3] |=> b`, each legal antecedent match end creates its own next-sample `b` obligation; deleting the obligation at the two-sample match end makes the trace fail.
- For exact counts 1/2/3 and equal range 2:2, the expected run of `a` samples passes when `b` is present at the next sample and fails when it is absent.
- Parameter-resolved delay 3 and exact repetition count 4 remain present in T-IR.

## Result

```text
PASS: sequence automata preserve ##0/##1/##2 implication alignment, exact/equal-bound and bounded-repetition obligations, resolved parameter bounds, and a replay-validated ##0 BMC counterexample.
```

The regression passed on 2026-11-19. This evidence supports SVA-005 through its two implication operators and multi-term sequence alignment, SVA-006 for fixed delays 0/1/2, SVA-007 for exact positive repetition, and SVA-008 for positive bounded repetition, each within its explicitly listed finite, single-clock, linear subset. It does not claim full IEEE SystemVerilog Assertions semantics, general property-monitor completeness, or proof of arbitrary RTL.
