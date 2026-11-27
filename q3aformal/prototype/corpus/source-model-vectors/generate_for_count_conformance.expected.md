# Expected Results — `generate_for_count_conformance.sv`

**Vector ID:** SM-047  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** RTL-029  
**Purpose:** Check zero, one, and multiple static generate-for iterations, resolved count identity, stable generated scope names, and a source-level count relation.

| `COUNT` | Expected iterations | Expected scoped signals | `is_one` |
|---:|---:|---|---:|
| 0 | 0 | none | 0 |
| 1 | 1 | `g_items[0].present` | 1 |
| 3 | 3 | `g_items[0..2].present` | 0 |

The independent elaboration oracle reconstructs the iteration indices from the static bound. Each model is also checked by a one-frame bounded assertion. A separate nonadvancing genvar update negative vector must reject with a source-located diagnostic.

Generated bit/part-select targets and repeated scoped declarations have additional RTL-029 evidence in the conformance map (SM-031 and SM-036). Dynamic iteration bounds remain unsupported.
