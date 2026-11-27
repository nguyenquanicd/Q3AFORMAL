# Expected T-IR — `generated_bit_assignment.sv`

**Top:** `generated_bit_assignment_top`  
**Manifest:** `prototype/generated-bit-assignment.q3a`

The top-level `g_desc` loop covers every bit of `y_desc[3:0]` exactly once and implements `y_desc[i] = a_desc[3-i]`. The `g_asc` loop covers every bit of the ascending declaration `y_asc[0:3]` and implements `y_asc[j] = a_asc[j]`. Direct descending/ascending part-selects cover `y_part[3:0]` and `y_part_asc[0:3]`. A generate-for loop with `k=0,2` resolves `y_genpart[k+1:k] = a_genpart[k+1:k]` into two constant part-select assignments that cover the vector. The parameterized child resolves `WIDTH=4`, covers `q[3:0]` once, and is flattened to the parent equation `child_y[i] = child_a[3-i]`.

The lowerer normalizes declaration indices and part-select ranges to least-significant-bit offsets, splits selected RHS expressions into bit equations, then emits one full-width equation per target. The independent regression evaluates the serialized T-IR expressions for all 16 four-bit input values. Expected numeric results are `reverse4(a_desc)`, `a_asc`, `a_part`, `a_part_asc`, `a_genpart`, and `reverse4(child_a)`, respectively. The same source is checked through bounded model checking: `p_all_targets_match` must return `BOUNDED_PASS`, while the intentionally false `p_desc_not_identity` must return a `BOUNDED_FAIL` with a replay-validated counterexample.

Negative manifests verify rejection of incomplete bit coverage, duplicate bit drivers, a whole-signal/selected-target conflict, a dynamic index, an out-of-range index, and a part-select direction inconsistent with the declaration. These vectors validate only this lowering slice; they are not a complete IEEE 1800 conformance result or a formal proof.
