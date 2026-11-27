# Expected Results — `casez_wildcard_positions.sv`

**Vector ID:** SM-043  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check static `casez` wildcards at different bit positions, overlapping source-order priority, and default selection.

The priority order is:

1. If `sel[2]` is 1 (`4'b?1??`), `code = 2'b00`.
2. Otherwise, if `sel[1]` is 1 (`4'b??1?`), `code = 2'b01`.
3. Otherwise, if `sel[0]` is 1 (`4'b???1`), `code = 2'b10`.
4. Otherwise, `code = 2'b11`.

| `sel` | Expected `code` | Selected item |
|---:|---:|---|
| `0000` | `11` | default |
| `0001` | `10` | `???1` |
| `0010` | `01` | `??1?` |
| `0011` | `01` | `??1?` precedes `???1` |
| `0100` | `00` | `?1??` |
| `0101` | `00` | `?1??` precedes `???1` |
| `0110` | `00` | `?1??` precedes `??1?` |
| `0111` | `00` | `?1??` precedes both later items |
| `1000` | `11` | default |
| `1001` | `10` | `???1` |
| `1010` | `01` | `??1?` |
| `1011` | `01` | `??1?` precedes `???1` |
| `1100` | `00` | `?1??` |
| `1101` | `00` | `?1??` precedes `???1` |
| `1110` | `00` | `?1??` precedes `??1?` |
| `1111` | `00` | `?1??` precedes both later items |

The vector uses two-valued selector inputs. Wildcards are static pattern characters only; runtime X/Z selector semantics are outside this profile.
