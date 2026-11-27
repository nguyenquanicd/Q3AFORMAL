# T017 RTL-025 Priority `if/else` Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-025, nested `if/else`  
**Regression:** `prototype/tests/test_process_control_oracle.ps1`

## Method

The regression checks the source-mapped priority mux in SM-009. The T-IR conditionals must preserve the source order `enable` (line 14), `select_a` (line 15), and `select_b` (line 17). The signal references map to their declarations (`data_a` line 5, `data_b` line 6, `data_c` line 7); the disabled-path zero literal maps to line 23, and the output equation maps to line 12.

The independent expected-behavior oracle covers all 131,072 combinations of `enable`, both select controls, three four-bit data values, and the case selector. This includes all four select-control combinations, including simultaneous `select_a=1` and `select_b=1`, which must select `data_a` by priority. The same regression requires the incomplete-assignment control to fail with the exact source-located diagnostic.

## Result

```text
PASS: T-IR structure/source mapping match the nested if/case RTL across all 131072 input combinations; the incomplete-assignment control is rejected at source line 6, column 5.
```

`prototype/tests/test_process_control_oracle.ps1` passed on 2026-11-20; exit code was 0. RTL-025 is Supported for this bounded nested-priority profile.

## Scope and limits

This validates the reviewed three-level priority mux and the no-latch complete-assignment control. X-condition semantics and other procedural shapes are excluded; this evidence does not establish all `if/else` source-to-T-IR boundaries. T017 remains open for the rest of the conformance matrix.
