# T016/T017 Expression Width Extension Progress

**Date:** 2026-11-16  
**Profile:** Q3A-P0-R0.9.1  
**Status:** Partial operator-level sizing and independent replay evidence. This does not establish full SystemVerilog sizing conformance.

## Implemented slice

The expression SAT encoder and independent witness replay now extend unequal-width operands to the maximum operand width for the tested binary arithmetic, relational, equality, and bitwise operators. The narrower operand is sign-extended only when both operands are signed; otherwise it is zero-extended. Conditional branches use the same signedness rule and the maximum branch width. Arithmetic results truncate carry or borrow at the selected result width.

The exact-width policy selected for module port connections remains unchanged. This operator sizing behavior applies inside expressions and does not permit mismatched module port connections.

## Evidence

`prototype/tests/test_sat_relational_bitblast.ps1` exhaustively checks 3-bit/2-bit operands for `<`, `<=`, `>`, `>=`, `==`, `!=`, `&`, `|`, `^`, `~^`, and `^~`, across all four signedness combinations and all 32 operand value pairs per combination. For each expected output bit it checks a satisfiable correct value and an unsatisfiable opposite value.

`prototype/tests/test_property_replay.ps1` independently replays the same operator/value/signedness combinations and checks every conditional branch selection for all 3-bit/2-bit branch values, both selector values, and all signedness combinations. The arithmetic/shift SAT oracle separately checks mixed-width addition/subtraction. `prototype/tests/test_bmc_mixed_width.ps1` also runs six source-level properties through parsing, T-IR lowering, SAT, and independent replay. Each property compares an operator result against an explicitly extended reference for unsigned relational/equality/bitwise operations and signed relational/arithmetic/conditional operations. These are finite, manually specified vectors.

## Limits and next work

This slice does not cover all IEEE 1800 context-determined sizing, unsized and unbased literals in every context, casts, concatenation sizing interactions, all widths through 64 bits, four-state equality, or complete source-to-T-IR conformance. The vectors are direct T-IR SAT/replay checks rather than an exhaustive source-level matrix. T016, T017, and T018 remain open.
