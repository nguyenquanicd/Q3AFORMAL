# Expected T-IR — Scoped generate-local declarations

**Vector ID:** SM-036  
**Profile:** Q3A-P0-R0.9.1  
**Top:** `generated_declaration_top`  
**Manifest:** `prototype/generated-scalar-declaration.q3a`

The top module declares one local signal in a selected named `generate if` block and one same-named local signal in each active named `generate for` iteration. The flattened model must keep the declarations distinct as `g_active.local_signal` and `g_lane[1..3].local_signal`. Each local equation must select the corresponding `a` bit. The four generated assignments must combine into one complete equation for `y`.

The instantiated child declares another `local_signal` in `g_child`. Its T-IR name must include the instance path `u_child.g_child.local_signal`, and the child output equation must reference that name. This checks that generated scope names remain distinct across both loop iterations and module instances. One-frame bounded SAT checks of `y == a` and `child_y == child_a` must return `BOUNDED_PASS` for the lowered model.

The T-IR checks are structural; the bounded SAT results establish the two relations only for the emitted model and do not establish complete SystemVerilog semantics or an independent behavioral proof. The implemented slice accepts active `logic` and `bit` declarations without initialization inside a scoped static generate block. Generate-local parameters, declarations without a generate-block scope, declaration initializers, and broader declaration/type semantics remain unsupported.

`generated-localparam-negative.q3a` and `generated-unscoped-declaration-negative.q3a` must fail before model generation with source-located diagnostics. The first rejects duplicate generate-local parameters in one block. The second rejects signal declarations outside a scoped generate block.
