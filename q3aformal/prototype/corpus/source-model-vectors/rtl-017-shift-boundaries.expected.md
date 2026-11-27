# RTL-017 Constant-Shift Boundary Expected Results

**Profile:** Q3A-P0-R0.9.1, two-state, four-bit unsigned left operand.

For every four-bit value of `a`, the source assertions must hold for every representable shift distance from 0 through 7. Logical shifts retain the four-bit left operand width and fill vacated bits with zero. A distance greater than or equal to the operand width yields zero.

| Distance | `a << distance` reference | `a >> distance` reference |
|---:|---|---|
| 0 | `a` | `a` |
| 1 | `{a[2:0], 1'b0}` | `{1'b0, a[3:1]}` |
| 2 | `{a[1:0], 2'b00}` | `{2'b00, a[3:2]}` |
| 3 | `{a[0], 3'b000}` | `{3'b000, a[3]}` |
| 4 | `4'b0000` | `4'b0000` |
| 5 | `4'b0000` | `4'b0000` |
| 6 | `4'b0000` | `4'b0000` |
| 7 | `4'b0000` | `4'b0000` |

`test_bmc_rtl_017_shifts.ps1` requires all 16 source properties to return `BOUNDED_PASS` at frame 0. The independent SAT bit-blaster and replay oracles separately enumerate all 16 input values at each distance and direction. This is complete distance/value coverage for this four-bit unsigned source vector, not general width, signedness, context-sizing, or source-to-model conformance proof.
