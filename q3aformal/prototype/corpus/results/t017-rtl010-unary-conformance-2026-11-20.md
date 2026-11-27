# T017 RTL-010 Unary-Operator Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-010, unary `+`, `-`, `!`, and `~`  
**Vector:** SM-049, `rtl_unary_conformance.sv`  
**Regressions:** `prototype/tests/test_unary_conformance.ps1` and `prototype/tests/test_sat_arithmetic_shift_bitblast.ps1`

## Method and result

The source-level regression checks each unary operator's T-IR operator kind, four-bit operand width, result width (4 bits except one-bit logical-not), and source mapping. An independent evaluator compares every operator with its numeric reference for all 16 unsigned four-bit values (64 comparisons). Four source assertions pass nonvacuously; a deliberately false unary-plus assertion produces a bounded failure whose witness passes independent replay. The separate SAT bit-blaster regression also passes its exhaustive four-bit unary-minus oracle.

Both regressions passed on 2026-11-20. RTL-010 is **Supported for the tested four-bit unsigned unary profile**.

## Limits

Signed unary operands, widths other than four, wider result/context interactions, and the complete source-to-model boundary matrix remain open. No general IEEE 1800 unary-operator claim is made.
