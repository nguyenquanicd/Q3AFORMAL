# Arithmetic and Shift Bit-Blasting Progress

**Date:** 2026-11-16  
**Profile:** Q3A-P0-R0.9.1  
**Status:** Partial focused SAT bit-blaster evidence; RTL/SVA source-to-model conformance remains open.

## Implemented

- Binary addition and subtraction over the T-IR result width, with carry/borrow truncated modulo that width.
- Operand extension to the result width: sign extension when both operands are signed, otherwise zero extension.
- Unary two's-complement negation modulo the operand width.
- Logical `<<` and `>>` with compile-time nonnegative distances. Distances greater than or equal to the left operand width produce zero.
- Compile-time distance evaluation for literal/constant values, concatenations, supported unary constant operators, and supported constant `+`, `-`, bitwise and shift expressions.
- Dynamic and negative shift distances fail closed with a source-located bit-blast diagnostic.
- Independent witness replay for the new arithmetic/shift expressions, including fail-closed replay of variable shift distances.
- Constant bit/part selects use elaborated packed-range bounds and normalize to least-significant-bit-first offsets; ascending and descending declarations are handled without changing bit order.
- Out-of-range, reversed-direction, dynamic, nested, and scalar selects fail closed during lowering.

## Evidence

`prototype/tests/test_sat_arithmetic_shift_bitblast.ps1` compiles and runs an independent C++ SAT oracle. It exhaustively enumerates every pair of 3-bit and 2-bit arithmetic inputs under all four operand signedness combinations for both addition and subtraction. It checks every 4-bit input for unary minus, every 4-bit input for shifts at every distance 0..7, every 8-bit input for normalized bit/part-select offsets, and rejection of dynamic and negative shifts. For each valuation, the expected output vector is satisfiable and flipping any one output bit while holding the other output bits fixed is unsatisfiable. `prototype/tests/test_property_replay.ps1` independently checks the replay evaluator over all 3-bit/2-bit arithmetic input pairs, all four signedness combinations, all 4-bit unary-minus inputs, and all 4-bit shifts at distances 0..7. `prototype/tests/test_bmc_arithmetic_shifts.ps1` runs five end-to-end RTL properties through project loading, T-IR, SAT query, witness decoding, and independent replay. `prototype/tests/test_bmc_selects.ps1` checks ascending/descending declared ranges end-to-end, independently checks their numeric MSB/LSB mapping through shift-derived references, and verifies dynamic/out-of-range/reversed-direction rejection.

The approved RTL-017 bounded four-bit unsigned profile is Supported: an RTL fixture checks both logical shift directions at all distances 0..7 against bit-concatenation or zero-fill references, with SAT, replay, and nonvacuous source-level assertions. A separate four-bit `>>>` prototype extension now has signed/unsigned SAT and replay oracles plus source-level BMC; it is outside the v0.10 profile until amended. SAT bit-blaster-only boundary checks cover selected shift distances at widths 1/4/8/16/32/64; source-level and replay conformance beyond four bits remains open. See `prototype/corpus/results/rtl-017-shift-boundaries-2026-11-19.md`, `prototype/corpus/results/t017-rtl017-arithmetic-right-shift-extension-2026-11-20.md`, and the corresponding test scripts. Other widths, context sizing, and full source-to-model boundaries remain open.

Observed results on 2026-11-16: `PASS: exhaustive arithmetic, constant-shift, and normalized-select bit-blasting matches independent vector oracles.` The focused replay, arithmetic BMC, and select BMC checks pass after the implementation changes; select BMC also confirms reversed-direction, out-of-range, and dynamic-select diagnostics.

## Limits

This evidence does not establish full SystemVerilog context-determined sizing, broad literal semantics, complete source-to-model correctness, all width boundaries through 64 bits, or full formal proof correctness. Select tests cover representative packed ranges, not all declared bounds, constants, or hierarchy shapes. Nested/indexed part-selects and cross-product operator-boundary testing remain open. The result does not close T016, T017, or T018.
