# T017 RTL-006 Sized-Literal Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-006, sized based integer literals  
**Vector:** SM-045, `rtl_sized_literal_resize.sv`  
**Regression:** `prototype/tests/test_sized_literal_resize.ps1`

## Method

The vector covers signed and unsigned binary, octal, decimal, and hexadecimal literals. It also checks unsigned zero extension, signed sign extension, and truncation of a sized literal. Equivalent conversions appear in continuous assignment, `always_comb`, and `always_ff` contexts.

The independent T-IR oracle checks all 14 lowered equations, operand/target widths, signedness, resize nodes, expected values, and source locations. Two bounded assertions are then checked through the SAT bit-blaster: one for all continuous and combinational values at frame 0 and one for the sequential resized state at frame 1.

## Result

```text
PASS: all 14 sized-literal equations preserve base, signedness, width, resize direction, source mapping, and independent values; SAT checks pass for continuous/combinational outputs and the sequential resized value.
```

The regression passed on 2026-11-20 with exit code 0. RTL-006 is Supported for direct, sized, two-state integer literal assignments within the documented width limit.

## Scope and limits

This change adds assignment conversion only for a direct sized literal. It does not add general context propagation into expressions containing sized literals, mixed sized-literal operator trees, X/Z digits, arbitrary precision, or complete IEEE 1800 expression sizing. Those remain fail-closed or outside the approved profile.

**Build ID:** aa15b6de86429c5c06ac854377ecd32657006ff4baad827cc8338c9165294828 (C++17 build from prototype/source/source_manager/build.ps1).
