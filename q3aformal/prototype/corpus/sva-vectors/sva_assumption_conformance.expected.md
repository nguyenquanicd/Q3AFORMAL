# Expected Results — `sva_assumption_conformance.sv`

**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** SVA-003  
**Purpose:** Check named concurrent assumptions, per-sample-frame constraint application, and explicit detection of contradictory assumptions.

For `sva_assumption_consistent`, `p_assume_a` constrains `a=1` and `p_assert_a` checks the same value. Across a three-frame bounded query, the only legal input sequence is `a[0..2]=111`; the assertion must pass nonvacuously.

For `sva_assumption_contradictory`, `p_assume_a_high` requires `a=1` while `p_assume_a_low` requires `a=0` at every sampled frame. An independent two-value oracle finds no legal value even at one frame. The tool must report `INCONSISTENT_MODEL_OR_ASSUMPTIONS`, not a property pass or a vacuous coverage result.

The T-IR must retain all assumption names, kinds, clock bindings, and source locations.
