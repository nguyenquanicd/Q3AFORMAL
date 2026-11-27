# T017 RTL-027 `casez` Wildcard-Position Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-027, static `casez` wildcard patterns  
**Regression:** `prototype/tests/test_casez_priority_oracle.ps1`

## Method

The existing overlap vector checks `1???` before `10??`, including all 16 values of the four-bit selector. The added SM-043 vector uses `?1??`, `??1?`, and `???1` in that source order, followed by a default branch. The independent oracle checks all 16 selector values, including overlaps where an earlier wildcard item must win.

The regression also checks the lowered `casez_match` pattern and mask values `(4,4)`, `(2,2)`, and `(1,1)`, the output code for each item, source lines 7–10, and the equation source location. This verifies that wildcard positions become the intended constrained-bit masks and that source order is preserved.

## Result

```text
PASS: both casez oracles check all 16 selector values; wildcard-position T-IR masks, source ordering, overlaps, defaults, and source mappings are exact.
```

`prototype/tests/test_casez_priority_oracle.ps1` passed on 2026-11-20; exit code was 0. RTL-027 is Supported for this bounded static-pattern profile.

## Scope and limits

This evidence covers static `?` wildcard patterns, overlapping item priority, default selection, and two-valued selector inputs for the reviewed four-bit vectors. Runtime X/Z selector values and general IEEE `casez` behavior remain unsupported. T017 remains open for other matrix rows.
