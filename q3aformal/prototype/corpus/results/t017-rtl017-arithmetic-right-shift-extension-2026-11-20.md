# RTL-017 Arithmetic Right-Shift Extension Evidence

**Date:** 2026-11-20  
**Implementation:** Internal SAT bit-blaster and independent witness replay. Source results below distinguish the historical experiment from the current Phase 0 CLI.
**Source vector:** `prototype/corpus/source-model-vectors/rtl-017-arithmetic-right-shift.sv`

## Scope

The experimental build extended the parser and formal engines for constant-distance `>>>`. A signed left operand copies its sign bit into vacated bits, while an unsigned left operand fills them with zero. The result width and signedness follow the left operand. The four-bit experiment checked distances 0 through 7.

The current proposed Phase 0 specification v0.10 explicitly lists arithmetic right shift as unsupported. Therefore this evidence records a prototype capability extension; adoption into the approved Phase 0 subset requires a specification/profile amendment. It does not change the support claim for the already-approved unsigned `<<`/`>>` slice.

## Evidence

- `test_sat_arithmetic_shift_bitblast.ps1` checks all 16 operand values, eight distances, both `>>` and `>>>`, and signed/unsigned operands: 512 four-bit input/operator/distance combinations. For each combination, expected outputs are satisfiable and every one-bit-different output vector is UNSAT. A separate symbolic bit-level oracle checks `<<`, `>>`, and `>>>` for signed/unsigned operands at widths 1, 4, 8, 16, 32, and 64, across six distinct boundary distances per width (198 width/operator/signedness/distance configurations total); each bit is proved equal to an independently mapped source bit or constant.
- `test_property_replay.ps1` validates the same 512 expected results and rejects 512 corrupted result traces. Replay and source-to-T-IR coverage remain limited to four-bit vectors; the wider configurations are a SAT bit-blaster boundary check only.
- The experimental build passed 16 source-level properties nonvacuously. On the current Phase 0 CLI, `test_bmc_rtl_017_arithmetic_right_shift.ps1` requires source-located rejection before a formal status.
- `test_bmc_rtl_017_shifts.ps1` still passes the previously approved logical-shift source regression.
- `test_bmc_rtl_017_unsupported_shifts.ps1` still rejects dynamic and negative shift distances with source locations and no formal status.

## Limits

Source and replay tests for the candidate use four-bit operands and constant nonnegative distances. Wider evidence covers the SAT bit-blaster. The Phase 0 frontend enforces the v0.10 exclusion of `>>>`.
