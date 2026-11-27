# RTL-017 Arithmetic-Shift Profile Amendment Candidate

**Status:** Proposed for profile review; not included in the current v0.10 Phase 0 subset.

## Current contract

The Phase 0 parser enforces the v0.10 exclusion of `>>>` with a source-located diagnostic. The SAT bit-blaster and replay retain the candidate operator for typed expressions and historical models.

## Proposed bounded addition

Add constant-distance `>>>` to RTL-017 for the current two-state, four-bit conformance slice:

- The result width and signedness follow the left operand.
- For a signed left operand, vacated high bits copy the sign bit.
- For an unsigned left operand, vacated high bits are zero.
- A distance at least the operand width yields sign-fill for a negative signed operand and zero otherwise.
- Only constant nonnegative shift distances are accepted; dynamic and negative distances remain rejected.

This candidate does not claim arbitrary-width or full IEEE 1800 expression-sizing conformance.

## Evidence available

See `prototype/corpus/results/t017-rtl017-arithmetic-right-shift-extension-2026-11-20.md`.

- 512 exact-value SAT bit-blaster oracle cases across signed/unsigned operands, `>>`/`>>>`, all four-bit values, and distances 0–7.
- 198 symbolic bit-level SAT configurations across widths 1, 4, 8, 16, 32, and 64, testing `<<`, `>>`, and `>>>` for signed/unsigned operands at boundary distances. These wider checks cover the bit-blaster only.
- 512 independent replay validations and 512 corrupted-result rejections.
- An experimental build previously passed 16 source-level bounded properties and checked typed intermediate representation (T-IR) metadata. The Phase 0 regression now requires source-located rejection before a formal result.
- Existing logical-shift and unsupported dynamic/negative-distance regressions continue to pass.

## Decision needed for a future profile revision

Before claiming this extension as part of the declared Phase 0 RTL/SVA subset, the profile owner should either:

1. approve a specification revision that adds the bounded four-bit `>>>` semantics above; or
2. retain the current Phase 0 rejection of `>>>`.

The tool remains a prototype either way; this note is only the RTL-017 scope decision and does not close T016, T017, T018, T019, T020, or the Phase 0 benchmark and Gate B work.
