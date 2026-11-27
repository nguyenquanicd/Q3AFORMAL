# T017 RTL-022 Nonblocking Sequential Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-022, positive-edge `always_ff` with nonblocking updates  
**Regression:** `prototype/tests/test_multi_process_transition_oracle.ps1`

## Method

The two-process vector checks two registers updated on the same clock edge. An independent oracle evaluates all 16 combinations of the two old register values, reset, and new input, requiring both next-state equations to use the same pre-edge values. The regression verifies source mappings for both process roots, reset conditions/values, and data assignments. It also runs a negative vector with a blocking assignment in `always_ff` and requires a source-located rejection at line 7, column 9.

## Result

```text
PASS: both always_ff processes share clk and match all 16 simultaneous pre-edge transition cases; reset/assignment source mappings are exact and blocking assignment rejects at line 7.
```

The regression passed on 2026-11-20 with exit code 0. RTL-022 is Supported for the bounded positive-edge, whole-signal nonblocking assignment profile.

## Scope and limits

The evidence covers separate clocked processes, sampled pre-edge reads, reset/data branch mapping, and rejection of blocking assignment in `always_ff`. It does not imply support for blocking sequential updates or establish complete RTL-to-T-IR conformance.
