# T017 SVA-003 Assumption-Frame Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** SVA-003, concurrent `assume property`  
**Vector:** `prototype/corpus/sva-vectors/sva_assumption_conformance.sv`  
**Regression:** `prototype/tests/test_sva_assumption_conformance.ps1`

## Method

The consistent top constrains `a=1` with a named positive-edge assumption and asserts `a` over three sampled frames. An independent exhaustive oracle enumerates all eight one-bit input sequences and confirms that only `111` satisfies both the assumption and assertion. The bounded query must pass nonvacuously over all three frames.

The contradictory top applies two named assumptions, `a` and `!a`, at the same positive-edge sample. An independent one-frame truth table confirms there is no legal value. The query must return `INCONSISTENT_MODEL_OR_ASSUMPTIONS`, rather than a property pass or a vacuous coverage result. The regression checks property names, kinds, clocks, expression locations, and assertion/assumption source locations in T-IR.

## Result

```text
PASS: assumption identities/source mappings are retained; the consistent assumption constrains all three sampled frames, and contradictory assumptions return INCONSISTENT_MODEL_OR_ASSUMPTIONS.
```

The regression passed on 2026-11-20 with exit code 0. SVA-003 is Supported for the tested scalar, single-clock concurrent assumption profile.

## Scope and limits

This evidence covers scalar assumptions at every active bounded sample, a consistent environment, explicit contradictory-assumption status, and T-IR identity/source mapping. Temporal assumption sequences remain bounded by the separately reviewed SVA subset; this does not establish complete IEEE SVA assumption semantics.
