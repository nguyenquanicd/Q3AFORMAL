# Expected results for packed type boundaries

`rtl_packed_type_boundaries.sv` complements the eight-bit range-direction corpus with a one-bit packed signal and two 64-bit words.

| Signal pair | Expected typed intermediate representation (T-IR) |
|---|---|
| `narrow_in` / `narrow_out` | Width 1, signed `bit` |
| `signed_in` / `signed_out` | Width 64, signed `logic`. Input index 0 and output index 63 both refer to the most significant bit. |
| `unsigned_in` / `unsigned_out` | Width 64, unsigned `bit`. Input index 63 and output index 0 both refer to the most significant bit. |

Direct assignment preserves bit significance across opposite directions. The signed comparison is negative exactly when the most significant bit is set. The unsigned value is always at least zero.

`test_packed_type_boundaries.ps1` checks the T-IR and requires five nonvacuous bounded model checking (BMC) passes. The deliberately false signed nonnegativity claim must produce a replay-validated 64-bit frame-zero value with its most significant bit set.
