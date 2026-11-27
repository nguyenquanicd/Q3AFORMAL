# Expected Results — multi_process_vectors.sv

**Vector ID:** SM-027  
**Profile:** Q3A-P0-R0.9.1

Two separate `always_ff` processes use the same positive-edge `clk` and synchronous reset. The transition relation is:

```text
a_q_next = rst ? 0 : new_a
b_q_next = rst ? 0 : a_q
```

Both next-state equations read the pre-edge state. In particular, `b_q_next` depends on the old `a_q`, not on `a_q_next`. `test_multi_process_transition_oracle.ps1` checks both state roles, the shared clock binding, and all 16 combinations of old `a_q`, old `b_q`, reset, and `new_a` against these independently written equations.
