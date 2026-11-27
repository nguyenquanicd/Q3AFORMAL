# Expected Results — `rtl_sized_literal_resize.sv`

**Vector ID:** SM-045  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check supported sized binary, octal, decimal, and hexadecimal literals, an explicitly signed literal, unsigned zero extension, signed sign extension, and truncation.

| Output | Expected value | Meaning |
|---|---:|---|
| `based_binary` | `8'hA6` | 8-bit binary literal |
| `based_octal` | `8'hA6` | 8-bit octal literal |
| `based_decimal` | `8'hA6` | 8-bit decimal literal |
| `based_hex` | `8'hA6` | 8-bit hexadecimal literal |
| `based_signed_binary`, `based_signed_octal`, `based_signed_decimal`, `based_signed_hex` | `8'h56` | Signed binary, octal, decimal, and hexadecimal literals; signed type metadata retained |
| `based_signed` | `8'h56` | 8-bit signed decimal literal |
| `unsigned_zero_extend` | `8'h0A` | 4-bit unsigned literal extended to 8-bit assignment width |
| `unsigned_zero_extend_comb` | `8'h0A` | 4-bit unsigned literal extended in `always_comb` |
| `signed_sign_extend` | `8'hFE` | 4-bit signed -2 extended to 8-bit assignment width |
| `signed_sign_extend_state` | `8'hFE` | 4-bit signed -2 extended in `always_ff` |
| `unsigned_truncate` | `4'h6` | 8-bit unsigned literal truncated to 4-bit assignment width |

The regression checks the lowered expression widths, signedness, exact source lines, and independent integer results. X/Z digits are outside this vector and remain rejected by the approved profile.
