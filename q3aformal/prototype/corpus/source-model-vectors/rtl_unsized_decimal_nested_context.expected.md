# Nested decimal arithmetic expected results

IEEE 1800-2023 sections 11.6 and 11.8 describe the operand widths and signs before the arithmetic is evaluated. Comparison operands share an arithmetic type and width while the comparison result is one unsigned bit.

| Property | Input condition | Expected result |
|---|---|---|
| `p_all_unsigned` | All 256 values of `x` | `2*x+1`, using an explicit 32-bit reference |
| `p_unsigned_carry` | `x=255` | `unsigned_sum=511` |
| `p_signed_carry` | `s=-128` | `signed_sum=0xff01`, the 16-bit representation of -255 |
| `p_mixed_zero_extension` | `s=-1`, `x=1` | `mixed_sum=512`, because the enclosing arithmetic is unsigned |
| `p_widen_before_negating` | `x=255` | `negated=0xff02`, the 16-bit representation of -254 |
| `p_sized_literal_context` | `s=127` | `based_sum=129` |
| `p_comparison_context` | `s=-1` | The 40-bit unsigned comparison sees 511 |
| `p_state_carry` | `x=255` on the sampled frame | `registered_sum=511` one cycle later |
| `p_decimal_on_other_side` | `x=255` | The right decimal operand gives `x+x` sufficient width to equal 510 |
| `p_shift_context` | All inputs | The constant shift distance is 8, giving `shifted=256` |

The two negative controls compare against the former truncated result or a wrong shift result. Their saved 511 and 256 values must replay. The constant shift witness must also revalidate after reopening the bundle.

Typed intermediate representation (T-IR) checks cover the width and signedness of inner operations, conversion of a signed source to unsigned before extension, placement of the final assignment resize, and preservation of source locations.
