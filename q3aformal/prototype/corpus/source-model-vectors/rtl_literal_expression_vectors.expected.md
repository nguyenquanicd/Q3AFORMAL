# Expected Results — rtl_literal_expression_vectors.sv

**Vector ID:** SM-008  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Add concrete literal, signedness, operator, selection, concatenation, conditional, and shift cases.

## Vector A

Drive u=4'hA, v=4'h5, small=2'b10, s=4'hF interpreted as signed -1, t=4'h1 interpreted as signed +1, and cond=1.

| Outputs | Expected values |
|---|---|
| bit_type_copy | 4'hA; packed two-state bit vector copied from u |
| unsized_positive, unsized_negative | 8'h01, 8'hFF |
| based_binary, based_octal, based_decimal, based_hex | 8'hA6 for all four |
| based_signed_negative | 8'hFE |
| fill_zero, fill_one | 4'h0, 4'hF |
| fill_zero_wide, fill_one_wide | 8'h00, 8'hFF |
| unary_plus, unary_minus, bitwise_not, logical_not | 4'hA, 4'h6, 4'h5, 1'b0 |
| add_wrap, subtract_wrap | 4'hB, 4'h9 |
| bitwise_and, bitwise_or, bitwise_xor, bitwise_xnor | 4'h0, 4'hF, 4'hF, 4'h0 |
| bitwise_and_mixed_width | 4'h2 when small=2'b10; the narrower unsigned operand is zero-extended to the expression width |
| logical_and, logical_or | 1'b1, 1'b1 |
| eq, ne | 1'b0, 1'b1 |
| unsigned_lt, unsigned_le, unsigned_gt, unsigned_ge | 0, 0, 1, 1 |
| signed_lt, signed_le, signed_gt, signed_ge | 1, 1, 0, 0 |
| signed_conditional | 8'hFF; the signed 4-bit -1 branch is sign-extended |
| concatenation | 8'hA5 |
| mixed_width_concatenation | 6'b101010 (6'h2A) when small=2'b10 |
| descending_select | 4'h2 from descending[6:3] |
| ascending_select | 4'h9 from ascending[0:3] |
| shift_left_0, shift_left_3, shift_left_4, shift_left_5 | 4'hA, 4'h0, 4'h0, 4'h0 |
| shift_right_0, shift_right_3, shift_right_4, shift_right_5 | 4'hA, 4'h1, 4'h0, 4'h0 |

## Case B — arithmetic and comparison boundaries

Drive u=4'hF, v=4'h1, small=2'b10, s=4'h7 interpreted as signed +7, t=4'h8 interpreted as signed -8, and cond=1.

- add_wrap=4'h0 and subtract_wrap=4'hE, showing four-bit modular arithmetic.
- unsigned_lt/unsigned_le/unsigned_gt/unsigned_ge = 0,0,1,1.
- signed_lt/signed_le/signed_gt/signed_ge = 0,0,1,1 for +7 compared with -8.
- unary_plus=4'hF, unary_minus=4'h1, and bitwise_not=4'h0.
- signed_conditional=8'h07 for the signed 4-bit +7 branch; with cond=0 it remains 8'h05.

## Logical truth table

| u is zero | v is zero | logical_and | logical_or |
|---:|---:|---:|---:|
| 1 | 1 | 0 | 0 |
| 1 | 0 | 0 | 1 |
| 0 | 1 | 0 | 1 |
| 0 | 0 | 1 | 1 |
Drive cond=0 for a second conditional case; signed_conditional must be 8'h05.

## Expected elaboration/model notes

- The unsized decimal literals 1 and -1 are handled using the profile's IEEE 1800 sizing/sign rules, then assigned to the declared 8-bit destinations.
- The sized binary, octal, decimal, and hexadecimal literals all encode 8'hA6.
- The unbased unsized fill literals take the destination width: '0 is four zero bits and '1 is four one bits.
- Unary and binary operation outputs retain their declared/context-resolved widths; four-bit arithmetic wraps modulo 16.
- Signed comparisons use signed four-bit values; unsigned comparisons use unsigned four-bit values.
- The descending packed range maps index 7 to the leftmost bit; the ascending packed range maps index 0 to the leftmost bit.
- Every output is a combinational equation. The module has no state.

## Remaining boundary review

This vector adds base and range examples but does not exhaust all widths, signed/unsigned mixing, truncation/extension combinations, or all shift distances. Those cases remain listed in coverage-map.md until individually authored and reviewed.





