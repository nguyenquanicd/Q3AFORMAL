# RTL-005 Mixed Unsized-Decimal Assignment Context Vectors

## Positive vector

`rtl_unsized_decimal_mixed_context.sv` exercises a restricted mixed signal/unsized-decimal subset: unary and binary `+`/`-` trees containing at least one unsized decimal literal.

| Target | Source expression | Expected source expression width | Conversion |
|---|---|---:|---|
| `u8_plus_one` | `u8_input + 1` | 32 bits, unsigned result | Truncate to 8 bits |
| `u8_minus_one` | `u8_input - 1` | 32 bits, unsigned result | Truncate to 8 bits |
| `u8_negated_plus_one` | `-(u8_input + 1)` | 32 bits, unsigned result | Truncate to 8 bits |
| `s8_plus_one` | `s8_input + 1` | 32 bits, signed result | Truncate to 8 bits |
| `s8_minus_one` | `s8_input - 1` | 32 bits, signed result | Truncate to 8 bits |
| `u16_plus_one` | `u8_input + 1` | 32 bits, unsigned result | Truncate to 16 bits |
| `u40_plus_one` | `u40_input + 1` | 40 bits, unsigned result | No width change |
| `comb_plus_one` | `u8_input + 1` | 32 bits, unsigned result | Truncate to 8 bits |
| `state_plus_one` | `s8_input + 1` | 32 bits, signed result | Truncate to 8 bits in `always_ff` |

The unsized decimal literal is signed and receives at least 32 bits. When the destination context is wider than 32 bits, the literal takes the 40-bit context. A mixed binary operation is unsigned if either operand is unsigned; otherwise its result is signed. Assignment resizing remains explicit in T-IR when the expression width differs from the destination.

The source assertion compares the generated 8-, 16-, and 40-bit outputs with references using explicitly sized arithmetic. The regression checks T-IR widths, signedness, and assignment-resize nodes, and requires the symbolic frame-0 assertion to return a non-vacuous bounded pass. A deliberately incorrect `u8_plus_one == u8_input + 8'd2` property must return `BOUNDED_FAIL` with a counterexample accepted by independent frame replay, exercising replay of the mixed expression and its assignment conversion.

## Negative vector

`negative-vectors/rtl_unsized_decimal_mixed_unsupported.sv` assigns `input_value * 3` to an 8-bit target. Multiplication is outside the approved Phase 0 operator subset. The frontend must reject it at the operator before starting a formal query.

## Scope

These vectors cover the listed decimal `+`/`-` expression forms and their assignment-context handling. They do not establish complete IEEE 1800 sizing, sized-literal context propagation, arbitrary mixed operators, arbitrary-precision decimal handling, or general source-to-T-IR conformance. RTL-005 remains Partial.
