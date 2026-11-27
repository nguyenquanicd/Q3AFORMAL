# RTL-017 Constant-Shift Boundary Evidence

**Date:** 2026-11-20  
**Profile:** Q3A-P0-R0.9.1  
**Status:** Supported for the tested four-bit unsigned constant-shift profile.

## Scope

The source fixture checks logical left and right shifts of a four-bit unsigned operand for every three-bit shift distance, 0 through 7. Expected values are independently written as bit concatenations or zero constants; the source assertions do not compare a shift expression with a duplicate copy of itself. Distances 4 through 7 exercise the width and greater-than-width zero-fill boundary.

## Results

| Evidence | Result |
|---|---|
| `prototype/tests/test_sat_arithmetic_shift_bitblast.ps1` | PASS; exhaustive four-bit values for both shift directions and all distances 0–7 match the independent expected-value oracle; each opposite output bit is UNSAT. |
| `prototype/tests/test_property_replay.ps1` | PASS; independent replay checks all 16 four-bit values for both directions and all distances 0–7. |
| `prototype/tests/test_bmc_rtl_017_shifts.ps1` | PASS; all 16 source properties parse, lower, and return `BOUNDED_PASS` at frame 0 against concatenation/zero-fill references. |
| `prototype/tests/test_bmc_rtl_017_unsupported_shifts.ps1` | PASS; dynamic and negative source distances return source-located nonzero errors and no formal-query status. |

The independent bit-blaster regression initially exposed a `const` loop-index typo in the test harness; after correcting it, the regression compiled and passed. No implementation defect was observed.

## Limits

This evidence completely covers shift distances and values for the single four-bit unsigned fixture only. It does not cover all operand widths, signed operands, every literal/context sizing interaction, or all accepted RTL source forms. Dynamic and negative distances remain unsupported and must reject before proof. The bounded RTL-017 profile is Supported; T016/T017 remain open for wider and general conformance.

The unsupported-distance regression observes rejection during selected-query bit-blasting, before a formal result is produced. It does not prove parse-time rejection. Wider shift widths, signed/context-sized RTL, and a complete independent source-to-model relation remain open.
