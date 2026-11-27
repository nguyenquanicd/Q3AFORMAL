# T017 RTL-023 Synchronous-Reset Isolation Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-023, synchronous reset in `always_ff`  
**Vector:** SM-044, `sync_reset_isolation.sv`  
**Regression:** `prototype/tests/test_sync_reset_isolation_oracle.ps1`

## Method

The fixture places a resettable state bit and an independently assigned state bit in the same positive-edge process. An independent oracle evaluates all 16 combinations of old state, reset, and input data. It then simulates six frames with reset held, released, and reasserted (`1,1,0,0,1,0`). The non-reset state must capture `data_in` on every frame, including while reset is asserted.

The regression also checks T-IR source locations: the clocked process at line 8, reset branch at line 9, reset value at line 10, reset deasserted assignment at line 12, and unreset assignment at line 14.

## Result

```text
PASS: 16 old-state/input valuations and six reset-held/released/reasserted frames match the independent oracle; reset source mappings and unreset state behavior are exact.
```

The regression passed on 2026-11-20 with exit code 0. RTL-023 is Supported for this bounded synchronous, active-high reset profile.

## Scope and limits

This evidence covers one positive-edge process, a synchronous active-high reset branch, two-state data, exact source mappings, and an independently updated state element outside the reset branch. Asynchronous reset and four-state reset behavior remain unsupported; this does not establish complete RTL-to-T-IR conformance.
