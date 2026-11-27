# Expected Results — `sva_assertion_conformance.sv`

**Profile:** Q3A-P0-R0.9.1  
**Matrix rows:** SVA-001, SVA-002  
**Purpose:** Check one positive-edge clock binding, concurrent assertion property identity/source mapping, a known-true property, and a known-false property with an independently replayed counterexample.

| Property | Expected result | Sampling point |
|---|---|---|
| `p_known_true` | `BOUNDED_PASS`, nonvacuous at frame 0 | `a || !a` evaluates on the sampled frame |
| `p_known_false` | `BOUNDED_FAIL`, replay validated, `a=0` at frame 0 | `a` is sampled before any state transition |

Both property records must bind to `clk`, retain kind `assert`, and map to their corresponding `assert property` source lines (8 and 13). The lowered model must list exactly one clock, `clk`.

An additional negative vector uses `@(negedge clk)` and must be rejected before bounded model checking because the accepted profile allows only the documented positive-edge event control.
