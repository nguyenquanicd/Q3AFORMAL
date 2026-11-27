# Expected Results — hierarchy_nested_vectors.sv

**Vector ID:** SM-025  
**Profile:** Q3A-P0-R0.9.1

`hierarchy_nested_top` instantiates `hierarchy_nested_middle`, which instantiates `hierarchy_nested_leaf`. The middle module passes the exact-width expression `lhs ^ rhs` to the leaf and ties its second input to `4'h0`. The leaf uses a complete `always_comb` process to compute the XOR and equality output.

Expected top-level behavior:

```text
u_middle.u_compare.xor_value = (lhs ^ rhs) ^ 4'h0
same = (u_middle.u_compare.xor_value == 4'h0)
```

Therefore `same` is one exactly when `lhs == rhs`. `test_hierarchy_lowering.ps1` evaluates all 256 pairs of four-bit inputs and checks the nested hierarchical signal name and both flattened equations. This vector covers two levels of unparameterized hierarchy, a nested expression-valued input, a child-local signal, and nested `always_comb` lowering. Active static generated instances and whole-signal assignments have focused coverage in SM-029/SM-030; scoped generate-local `logic`/`bit` declarations have focused coverage in SM-036. Expression-valued output actuals remain outside the supported slice. Constant/generated bit and part-select assignment targets have focused coverage in SM-031. Parameterized hierarchy has separate width vectors.
