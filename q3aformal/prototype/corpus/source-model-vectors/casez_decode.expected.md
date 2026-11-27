# casez Decode Expected Behavior

The selector is a two-valued four-bit input. Items are evaluated in source order:

| `sel` pattern | Expected `code` | Reason |
|---|---:|---|
| `1???` | `2'b01` | First case item; matches every selector with bit 3 set |
| `10??` | `2'b10` | Overlaps `1???`, so it is shadowed by the first item where both match |
| default | `2'b00` | Selected when bit 3 is clear |

Therefore, for all 16 selector values, `code` is `2'b01` when `sel[3] == 1` and `2'b00` otherwise. `test_casez_priority_oracle.ps1` exhaustively compares the lowered expression with this independent truth table. The overlap is intentional: it detects a reversed priority or a wildcard-mask error. This does not establish general IEEE casez conformance.
