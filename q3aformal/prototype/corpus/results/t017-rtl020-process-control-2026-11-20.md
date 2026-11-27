# T017 RTL-020 Process-Control Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-020, complete `always_comb` assignment  
**Regression:** `prototype/tests/test_process_control_oracle.ps1`

## Method

The regression lowers the reviewed SM-009 source vector and checks that the emitted T-IR has exactly two combinational equations, no clocks, and no next-state equations. It checks that the priority output is represented by the source-mapped nested `enable` → `select_a` → `select_b` conditional, and that the case output retains source-ordered exact comparisons for `2'b00`, `2'b01`, and `2'b10`, followed by the default `4'hF` branch.

An independent expected-behavior oracle evaluates the lowered T-IR against all 131,072 combinations of the three one-bit controls, three four-bit data inputs, and the two-bit selector. The expected equations are computed directly from the reviewed expected-result document, independently of the T-IR evaluator.

The same regression lowers the RTL-021 incomplete-assignment control and requires the source-located rejection at line 6, column 5 before model generation.

## Result

```text
PASS: T-IR structure/source mapping match the nested if/case RTL across all 131072 input combinations; the incomplete-assignment control is rejected at source line 6, column 5.
```

`prototype/tests/test_process_control_oracle.ps1` passed on 2026-11-20; exit code was 0. The RTL-020 matrix row is now Supported for this bounded complete-assignment profile.

## Scope and limits

This validates the reviewed SM-009 nested-if/exact-case example and the RTL-021 incomplete-assignment rejection control. It does not establish conformance for every legal `always_comb` syntax, nested case combinations, all statement widths, or complete RTL-to-T-IR semantics across the profile; T017 and broader T016 conformance remain open.
