# Combinational Child Process Expected Behavior

**Vector ID:** SM-019  
**Profile:** Q3A-P0-R0.9.1, specification revision 0.10

`hierarchy_process_top` instantiates one `hierarchy_process_leaf`. The child has only input/output ports and one complete `always_comb` process. Its expected relation is:

```text
hierarchy_process_top.same = (hierarchy_process_top.lhs == hierarchy_process_top.rhs)
```

The flattened T-IR has exactly one combinational equation targeting `same`; the equality operands refer to top-level `lhs` and `rhs`, not child formal names. The output is 1 for equal inputs and 0 otherwise. The test checks representative equal and unequal values for both the continuous-assignment and `always_comb` child variants.

This vector covers one child using whole-signal ports. Nested hierarchy and parameter/localparam metadata have separate vectors; active static generated-instance and whole-signal assignment cases have focused coverage in SM-029/SM-030. This vector does not cover output-select actuals; scalar output-bit connections are covered separately by SM-033/SM-035, sequential output part-selects by SM-037, and combinational output part-selects by SM-038. Scoped generate-local `logic`/`bit` declarations are covered in SM-036; generated local parameters, declaration initializers, unscoped declarations, dynamic/indexed output selects, and expression-valued output actuals remain unsupported. Constant/genvar bit and part-select assignment lowering is covered separately by SM-031. Child input expressions from the supported typed subset are covered by SM-020; child-local combinational signals are covered by SM-021.
