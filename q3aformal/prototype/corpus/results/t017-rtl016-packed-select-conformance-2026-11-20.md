# T017 RTL-016 Packed-Select Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-016, constant bit/part select  
**Vector:** SM-048, `bmc_selects.sv`  
**Regression:** `prototype/tests/test_bmc_selects.ps1`

## Method

The regression lowers the source and checks each of nine selected output equations for its source line, result width, select kind, packed input, and normalized T-IR offset. An independent numeric reference evaluates all 256 values of each input vector, for 2,304 exact comparisons covering `[7:0]` and `[0:7]` declarations, single-bit selections, both nibbles, and the constant range expression `[1 + 2:0]`.

Eight source assertions compare direct select results with independently shifted reference bits/nibbles. Each must return nonvacuous `BOUNDED_PASS`; eight deliberately false properties must return `BOUNDED_FAIL` with independently validated replay. Dynamic, out-of-range, and reversed-direction selections must return the expected lowering diagnostic and no formal status.

## Result

`test_bmc_selects.ps1` passed on 2026-11-20. RTL-016 is **Supported for the tested direct constant-select profile**: eight-bit ascending/descending packed declarations, constant bit/part selects, and the tested constant index expression.

## Limits

This does not establish nested select, indexed part-select, arbitrary widths, or the full expression-boundary matrix. Dynamic, out-of-range, and reversed-direction forms are rejected in this profile. T016/T017 remain open for other constructs and broader source-to-T-IR conformance.
