# T017 SVA-001/SVA-002 Clock and Scalar Assertion Evidence

**Date:** 2026-11-20  
**Matrix rows:** SVA-001 (single positive-edge clock), SVA-002 (concurrent `assert property`)  
**Vector:** `prototype/corpus/sva-vectors/sva_assertion_conformance.sv`  
**Regression:** `prototype/tests/test_sva_assertion_conformance.ps1`

## Method

The positive vector declares one clock and two concurrent scalar assertions. The regression verifies the T-IR has exactly one clock (`clk`), both records retain kind `assert` and bind to `clk`, and the assertion statements and predicates map to their exact source lines. A known-true property is checked at frame 0. A known-false property must produce a nonvacuous frame-0 counterexample with `a=0` and pass independent replay.

A separate negative vector uses `@(negedge clk)`. It must fail during parsing at line 6, column 11, before any bounded query status is produced.

## Result

```text
PASS: one positive-edge clock and both assertions retain exact T-IR mappings; known-true passes, known-false replays a frame-0 failure, and negedge rejects before BMC.
```

The regression passed on 2026-11-20 with exit code 0. SVA-001 and SVA-002 are Supported for the tested single-clock, scalar concurrent assertion profile.

## Scope and limits

This evidence covers one bound positive-edge clock, scalar concurrent assertions, property/predicate source mapping, a nonvacuous pass, a replay-validated failure, and fail-closed rejection of a negative edge. Immediate assertions, multiple clocks, other edges, complete IEEE sampling/event scheduling, and general SVA monitor semantics remain unsupported or outside the accepted profile.
