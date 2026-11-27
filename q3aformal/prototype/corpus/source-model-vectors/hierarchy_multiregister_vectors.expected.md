# Simultaneous Child Register Update Expected Behavior

**Vector ID:** SM-023  
**Profile:** Q3A-P0-R0.9.1, specification revision 0.10

The child has two one-bit registers on the shared top-level clock. At each active edge:

```text
a_q_next = rst ? 0 : new_a
b_q_next = rst ? 0 : a_q
out_a = a_q
out_b = b_q
```

Both next-state equations must read the same pre-edge state. In particular, `b_q_next` uses the old `a_q`, not `a_q_next`. `test_hierarchy_lowering.ps1` checks all 16 combinations of old `a_q`, old `b_q`, reset, and `new_a` against these independent equations.
