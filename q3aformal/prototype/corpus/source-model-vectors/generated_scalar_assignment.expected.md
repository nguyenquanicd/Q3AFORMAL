# Expected T-IR — generated_scalar_assignment.sv

**Profile:** Q3A-P0-R0.9.1  
**Top:** generated_assignment_top  
**Manifest:** prototype/generated-scalar-assignment.q3a

With default ENABLE=1 and BASE=2, the generate-if selects g_enabled. The generate-for loop executes once with i=2; the generated whole-signal equation is y = a XOR 2. The inactive branch refers to unresolved_inactive_signal; that expression must not appear in the lowered T-IR.

The top instantiates generated_assignment_cell with parameter override BASE=5. Its generate-for loop executes once with j=5. The flattened child output equation is child_y = a XOR 5, proving parameter-aware genvar resolution in a child module and direct output-port aliasing.

The regression also checks the elaboration report contains the active assignment path g_enabled.g_item[2] and the resolved i=2 value. `generated_scalar_declaration.sv` is a separate positive structural vector for scoped generate-local declarations; see [SM-036](generated_scalar_declaration.expected.md).

## Supported boundary

- Active static generate-if/for scopes containing whole-signal continuous assignments.
- Resolved parameter and genvar values in assignment expressions.
- Direct top-level and child-module assignments subject to existing exact-width, alias, and driver checks.
- Inactive branch assignments are not lowered.

This vector does not cover generated declarations. Multiple active assignments to one whole-signal target are rejected; complete unique constant/genvar bit and part-select sets are implemented but are not covered by this vector. This vector is structural lowering evidence, not an independent behavioral oracle or a proof result.
