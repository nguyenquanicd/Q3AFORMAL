# Expected T-IR — `generated_scalar_instance.sv`

**Profile:** Q3A-P0-R0.9.1  
**Top:** `generated_scalar_top`  
**Manifest:** `prototype/generated-scalar-instance.q3a`

With the default `ENABLE=1` and `LIMIT=2`, the generate-if selects `g_enabled`; the `g_disabled` branch contains an unresolved module and must remain unelaborated. The generate-for loop starts at `i=1` and executes exactly once. It creates instance `g_enabled.g_item[1].u`, and the instance parameter `INVERT` resolves to 1 from the genvar expression.

The flattened model must contain:

- Child-local signal `g_enabled.g_item[1].u.inverted`.
- Instance parameter `g_enabled.g_item[1].u.INVERT = 1`.
- Equation `g_enabled.g_item[1].u.inverted = ~a` after constant propagation of the `INVERT` condition.
- Equation `y = g_enabled.g_item[1].u.inverted`.

The regression checks this generated hierarchy path, parameter value, and equation structure in serialized T-IR. This is a focused lowering vector; it does not establish all generate-for widths or generated bit-select assignment behavior. Scoped generate-local `logic`/`bit` declarations have separate focused evidence in SM-036. Output actuals such as `data_out[i]` also remain unsupported. Constant/genvar bit and part-select assignment targets have a separate ordering regression in SM-031.
