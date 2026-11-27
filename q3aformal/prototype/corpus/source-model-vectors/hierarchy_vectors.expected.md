# Expected Results — hierarchy_vectors.sv

**Vector ID:** SM-007  
**Profile:** Q3A-P0-R0.9.1, specification revision 0.10
**Purpose:** Check deterministic module resolution, instance-path preservation, and named-port connection mapping.

## Configuration

Elaborate hierarchy_top as the top module. It instantiates one hierarchy_leaf instance named u_compare.

For lhs=4'hA and rhs=4'hA, expected same=1'b1. For lhs=4'hA and rhs=4'hB, expected same=1'b0.

## Expected elaborated hierarchy and connections

- Top path: hierarchy_top.
- Child path: hierarchy_top.u_compare, module type hierarchy_leaf.
- hierarchy_leaf.a is driven by hierarchy_top.lhs.
- hierarchy_leaf.b is driven by hierarchy_top.rhs.
- hierarchy_leaf.equal drives hierarchy_top.same.
- The child's `a`, `b`, and `equal` port widths are checked against the corresponding parent actuals (4, 4, and 1 bit); implicit resizing is rejected.
- The leaf's equality expression is expected to lower as a one-bit Boolean relation over two unsigned four-bit vectors in T016.
- No state elements or clock transitions are introduced.

## Positional instance case

When hierarchy_positional_top is selected as the top, the positional connection order follows hierarchy_leaf's declaration order: lhs connects to a, rhs connects to b, and same receives equal. For lhs=4'h6 and rhs=4'h6, expected same=1'b1; for rhs=4'h7, expected same=1'b0.
## Negative elaboration cases

- Selecting a nonexistent top must produce a source-located missing-top diagnostic.
- Removing hierarchy_leaf must produce an unresolved-module diagnostic; no black-box behavior may be invented.
- An invalid named port must stop elaboration before query generation. The owner selected an exact-width restriction for profile Q3A-P0-R0.9.1. Reject any connected-port bit-width mismatch before T-IR generation; do not insert implicit extension or truncation.

## Implementation boundary

The T015 elaborator observes named and positional port mappings, exact-width rejection, direct instance paths, parameterized hierarchy, and recursive-instantiation rejection. T016 lowers recursively nested parameterized or unparameterized modules containing supported continuous assignments, complete `always_comb`, and the selected one-clock `always_ff` subset. Child-local signals and state use full hierarchical names; resolved parameter/localparam values are namespaced by instance path in T-IR metadata. Child input actuals may be expressions from the supported subset with exact formal width; child output actuals may be whole parent-scope signals or constant, direction-matched packed-parent bit/part-selects with exact formal width and complete bus coverage. `test_hierarchy_lowering.ps1` checks named/positional connection styles, two-level combinational and sequential hierarchy, and parameter widths 2, 3, and 4. Active static generate-if/for instances and whole-signal assignments have focused coverage in SM-029/SM-030; scoped generate-local `logic`/`bit` declarations have focused coverage in SM-036; direct/wrapped constant sequential child output part-selects have focused coverage in SM-037; direct/wrapped combinational child output part-selects have focused bounded-property coverage in SM-038. Generate-local parameters, declaration initializers, unscoped generated declarations, dynamic/indexed child output selects, expression-valued output actuals, broader generated bit-select source-map verification beyond focused SM-031/SM-033 evidence, and full independent implementation-versus-oracle evaluation remain open under T016/T017.




