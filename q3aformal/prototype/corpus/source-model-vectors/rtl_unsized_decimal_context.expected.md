# Expected Results — `rtl_unsized_decimal_context.sv`

**Vector ID:** SM-042  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** RTL-005  
**Scope:** Unsized decimal literals and literal-only unary/add/sub expressions in assignment contexts.

## Expected values

| Signal | RTL expression | Expected value |
|---|---|---:|
| `u8_one` | `1` assigned to 8 bits | `8'h01` |
| `u8_truncate` | `257` assigned to 8 bits | `8'h01` |
| `s8_negative` | `-2` assigned to signed 8 bits | `8'hFE` |
| `u40_one` | `1` assigned to 40 bits | `40'h0000000001` |
| `s40_negative` | `-2` assigned to signed 40 bits | `40'hFFFFFFFFFE` |
| `u8_sum` | `1 + 2` assigned to 8 bits | `8'h03` |
| `comb_value` | `always_comb: 3` assigned to 8 bits | `8'h03` |
| `state_value` next value | `always_ff: -4` assigned to 8 bits | `8'hFC` |

## Expected T-IR sizing

- Unsized decimal literals are signed and have at least 32 bits.
- For the 8-bit assignment cases, the literal-only RHS keeps its 32-bit expression width. T-IR contains an explicit `assignment_resize` node to represent assignment conversion to the 8-bit destination.
- For the 40-bit assignment cases, the assignment context widens the literal-only expression to 40 bits. The negative expression is evaluated at that width.
- Assignment conversion truncates high bits when narrowing and sign-extends a signed RHS when widening. The converted expression carries the destination signal's width and signed type.
- The fixture exercises continuous assignments, a complete `always_comb`, and an `always_ff` next-state assignment. The checked property intentionally covers only combinational outputs; the state next-value sizing is inspected directly in T-IR.

## Conformance boundary

This vector covers literal-only decimal expressions and unary `+`/`-` or binary `+`/`-` compositions. It does not establish complete IEEE 1800 expression typing, mixed signal/literal context propagation, real or arbitrary-precision literals, or general assignment conversion. The prototype accepts decimal magnitudes only within its signed 64-bit parser range and formal bit-blasting is limited to 64 bits.

The sizing rules are based on IEEE Std 1800-2017 Sections 5.7.1, 11.6, and 11.8.3. The standard identifies unsized numbers as at least 32 bits and describes context-determined assignment expression sizing and truncation/extension. See the [IEEE 1800-2023 standard record](https://standards.ieee.org/ieee/1800/7743/) and [IEEE 1800-2017 text](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf).
