# Child-Local Combinational Signal Expected Behavior

**Vector ID:** SM-021  
**Profile:** Q3A-P0-R0.9.1, specification revision 0.10

The child declares a 4-bit local signal `xor_value`, computes it as `a ^ b`, and drives the parent output from `(xor_value == 0)`. For instance `u_compare`, the flattened T-IR must contain `u_compare.xor_value` with role `internal` and width 4, plus these relations:

```text
u_compare.xor_value = lhs ^ rhs
same = (u_compare.xor_value == 4'h0)
```

`test_hierarchy_lowering.ps1` evaluates both equations in T-IR order and compares `same` against the independent relation `(lhs ^ rhs) == 0` for representative input pairs.

This vector covers a combinational child-local signal in a single leaf. Child sequential state and two-level unparameterized hierarchy are covered separately by SM-022 and SM-025/SM-026. Active static generated instances and whole-signal generated assignments have focused coverage in SM-029/SM-030; scoped generate-local `logic`/`bit` declarations have separate focused coverage in SM-036. Constant/genvar bit and part-select assignment lowering has ordering and fail-closed regression coverage in SM-031.
