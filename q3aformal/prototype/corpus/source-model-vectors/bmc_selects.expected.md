# Expected Results — `bmc_selects.sv`

**Vector ID:** SM-048  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** RTL-016

For packed `[7:0]`, bit `i` maps to numeric bit `i`, `[3:0]` maps to the low nibble, and `[7:4]` maps to the high nibble. For packed `[0:7]`, index `0` maps to the most-significant numeric bit, index `7` to the least-significant bit, `[0:3]` to the high nibble, and `[4:7]` to the low nibble. The constant expression `[1 + 2:0]` must resolve as `[3:0]`.

`test_bmc_selects.ps1` checks all 256 values for each of nine lowered bit/part-select equations against an independent numeric reference (2,304 value comparisons), exact T-IR kind/width/normalized offset/source-line mapping, eight nonvacuous bounded mapping assertions, and eight replay-validated intentionally false assertions. Dynamic, out-of-range, and reversed-direction selects must reject during lowering without a formal result.

This vector covers direct, constant-index and constant-range selection on eight-bit ascending/descending packed declarations. It does not define nested, indexed-part-select, or broader-width behavior.
