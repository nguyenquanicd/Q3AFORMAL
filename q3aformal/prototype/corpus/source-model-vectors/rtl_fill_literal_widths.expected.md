# Expected Results — Unbased Unsized Fill Widths

**Vector ID:** SM-041  
**Matrix row:** RTL-007  
**Profile:** Q3A-P0-R0.9.1

The unbased unsized fill literal `'0` replicates zero to the destination width, and `'1` replicates one. The source checks destination widths 2, 5, and 13 bits, in addition to the existing 4-bit and 8-bit examples in SM-008.

| Destination width | `'0` expected value | `'1` expected value |
|---:|---|---|
| 2 | `2'b00` | `2'b11` |
| 4 | `4'h0` | `4'hF` |
| 5 | `5'b00000` | `5'b11111` |
| 8 | `8'h00` | `8'hFF` |
| 13 | `13'b0` | `13'b1_1111_1111_1111` |

The property `p_fill_context_width` asserts the all-zero and all-one values at widths 2, 5, and 13. The independently inspected T-IR must retain the destination width on each fill literal and preserve its `'0` or `'1` value. X/Z unbased fill literals are outside the two-state profile and must be rejected before lowering or proof.
