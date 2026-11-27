# Expected Results — operator_vectors.sv

**Vector ID:** SM-005  
**Profile:** Q3A-P0 RTL profile, specification revision 0.9  
**Purpose:** Check listed unary/binary operators, resolved widths, signedness, concatenation, selects, shifts, and conditional selection.

## Case A

Drive a=4'hA, b=4'h5, sa=4'hF as signed four-bit (-1), and sb=4'h1 as signed four-bit (+1).

| Output | Expected | Derivation |
|---|---:|---|
| add_y | 4'hF | 10 + 5 modulo 16 |
| sub_y | 4'h5 | 10 - 5 |
| unary_minus_y | 4'h6 | -10 modulo 16 |
| bit_not_y | 4'h5 | Four-bit complement of A |
| logical_not_y | 1'b0 | A is nonzero |
| and_y | 4'h0 | A & 5 |
| or_y | 4'hF | A \| 5 |
| xor_y | 4'hF | A ^ 5 |
| xnor_y | 4'h0 | Bitwise complement of F |
| logical_and_y | 1'b1 | Both operands are nonzero |
| logical_or_y | 1'b1 | At least one operand is nonzero |
| eq_y | 1'b0 | A differs from 5 |
| ne_y | 1'b1 | A differs from 5 |
| unsigned_lt_y | 1'b0 | Unsigned 10 < 5 is false |
| signed_lt_y | 1'b1 | Signed -1 < +1 |
| mux_y | 4'h5 | a[0]=0 selects b |
| concat_y | 8'hA5 | {a,b} preserves source order |
| bit_select_y | 1'b1 | a[3] is 1 |
| part_select_y | 4'hA | concat_y[7:4] |
| left_shift_y | 4'h4 | A << 1, truncated to four bits |
| right_shift_y | 4'h5 | A >> 1, zero-filled |

## Case B — conditional true branch

Drive a=4'h9, b=4'h3, sa=4'hF, and sb=4'h1.

Expected mux_y=4'h9 because a[0]=1; this covers the other conditional branch. Other outputs follow the equations in the source and should be computed independently for any full-vector comparison.

## Expected elaborated/T-IR properties

- Every port is a two-valued packed bit-vector with the declared width and signedness.
- Every continuous assignment has one driver.
- signed_lt_y compares signed four-bit operands; unsigned_lt_y compares unsigned four-bit operands.
- The shift results retain the left operand width.
- The concatenation order is a in bits [7:4] and b in bits [3:0].
- No state elements or clock transitions are introduced.

## Review limits

These hand-calculated points are reference examples, not execution results. Boundary vectors for every operator width, signed extension, truncation, and shift distance remain required before the operator rows can be marked conformant.
