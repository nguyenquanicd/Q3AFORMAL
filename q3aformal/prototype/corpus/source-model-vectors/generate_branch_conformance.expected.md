# Expected Results — `generate_branch_conformance.sv`

**Vector ID:** SM-046  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** RTL-028  
**Purpose:** Check outer and nested static `generate if` selection, active branch identity, selected assignment source mapping, and behavior for true/false branches.

| `ENABLE` | `WIDTH` | Selected equation | Expected `y` |
|---:|---:|---|---|
| 1 | 4 | `g_enabled.g_width_four`: `a ^ b` | `a ^ b` |
| 1 | 3 | `g_enabled.g_width_other`: `a & b` | `a & b` |
| 0 | 4 | `g_disabled`: `'0` | `4'b0000` |
| 0 | 3 | `g_disabled`: `'0` | `3'b000` |

The independent oracle evaluates every input pair for all four configurations (640 total cases). Each configuration also checks the source-level assertion with a one-frame bounded SAT query. The T-IR equation must map to source line 13, 15, or 18 according to the selected branch; inactive nested branches must not contribute equations.
