# Source-to-Model Vectors

These are original Phase 0 RTL inputs. They are conformance-corpus sources, not proof that the future frontend already implements the profile. Each expected result below is the review oracle for parser/elaboration/T-IR work.

## Vector SM-001 — counter4_pass.sv

- Top: counter4_pass.
- State: unsigned 4-bit count; S[0] is unconstrained.
- Input: clk, rst; one positive-edge clock.
- Expected transition at each active edge:
  - If rst is 1, count' = 0.
  - Otherwise, if count = 15, count' = 0.
  - Otherwise, count' = count + 1 modulo 16.
- Property: if count is 15 at sample t, count is 0 at sample t+1.
- Expected status: PROVEN with checked induction/invariant evidence. A finite bounded miss alone is not sufficient.
- Source map: each transition branch and property maps to its source span.

## Vector SM-002 — counter4_fail.sv

The source differs from SM-001 only in the wrap branch: count' = 1 when count = 15 and reset is deasserted.

- Expected witness: choose S[0].count = 15 and rst[0] = 0. At sample 0 the antecedent is true; S[1].count = 1; the consequent at sample 1 is false.
- Expected status: FAIL only after replay validates every transition and the failing property sample.
- This vector also checks that an unconstrained initial state may begin at 15.

## Vector SM-003 — casez_decode.sv

- Selector and output are packed two-valued vectors.
- casez patterns are checked in source order; the first matching item wins.
- sel = 4'b1010 matches both 4'b1??? and 4'b10??; expected code = 2'b01 because the first item wins.
- sel = 4'b1100 matches 4'b1???; expected code = 2'b01.
- sel = 4'b0100 matches no listed pattern; expected code = 2'b00 from default.
- Any runtime X/Z selector value is unsupported and must be rejected or excluded by the model contract.

## Vector SM-004 — handshake1_entry.sv

- State: full and data_q; both reset synchronously to zero.
- Combinational relations: in_ready = not full or out_ready; out_valid = full; out_data = data_q.
- At an active edge with reset: full' = 0 and data_q' = 0.
- At an active edge without reset and in_ready: full' = in_valid; data_q' = in_data when in_valid is 1.
- At an active edge without reset and not in_ready: state holds.
- The stalled-output property checks that valid remains asserted after a sampled stall.
- The data-stability property uses $past at delay 1. The generated history-valid guard suppresses evaluation until one prior sample exists. On later samples, a previous stalled condition requires the output to remain valid and data to match its previous sampled value.
- Reset does not clear the generated SVA history state; reset handling is explicit in the property antecedent and the result model.

## Vector SM-005 — operator_vectors.sv

See operator_vectors.expected.md for hand-calculated arithmetic, logical/bitwise, signedness, select, concatenation, conditional, and shift results. This is a set of representative points; operator boundary coverage remains incomplete.

### Focused mixed-width implementation fixture

`bmc_mixed_width.sv` and `bmc-mixed-width.q3a` are an implementation regression, not a replacement for the reviewed matrix corpus. Six bounded properties compare selected signed and unsigned mixed-width RTL expressions against explicitly extended references; `test_bmc_mixed_width.ps1` checks SAT status and independent replay. The vectors exercise parsing, lowering, and query integration but do not establish full IEEE 1800 sizing conformance.

### Linear implication cover fixture

`bmc_cover_implication.sv` exercises overlapped and non-overlapped cover implications, including a multi-term antecedent, through the source-to-BMC path. `test_bmc_cover_implication.ps1` checks replayed witnesses and a bound-limited non-overlapped query. The reported `COVERED` result requires a nonvacuous antecedent/consequent match; IEEE vacuity coverage counters remain outside this prototype slice.

## Vector SM-006 — generate_vectors.sv

See generate_vectors.expected.md for WIDTH=4 and WIDTH=3 generate branch selection, loop unrolling, expected bit equations, and elaborated names. Zero/one-iteration and invalid-bound cases remain incomplete.

## Vector SM-007 — hierarchy_vectors.sv

See hierarchy_vectors.expected.md for the top/child instance path, named/positional mapping, equality oracle, exact-width rule, and negative hierarchy diagnostics. T016 lowers this direct unparameterized leaf equality and recursively lowers nested/stateful hierarchy; full T017 conformance remains open.
## Vector SM-008 — rtl_literal_expression_vectors.sv

See rtl_literal_expression_vectors.expected.md for concrete expected values across integer literal categories, fill literals, arithmetic/logic, signed/unsigned comparisons, branch sizing, concatenation, ascending/descending selects, and shift boundary distances.

## Vector SM-040 — rtl_concat_three.sv

See rtl_concat_three.expected.md and [RTL-015 conformance evidence](../../../evidence/conformance/rtl-015-concat-three-2026-11-19.md) for a fixed-width three-member concatenation, source-order layout, all 64 packed-input values, and the checked bit-slice relation.

## Vector SM-041 — rtl_fill_literal_widths.sv

See rtl_fill_literal_widths.expected.md and [RTL-007 conformance evidence](../../../evidence/conformance/rtl-007-fill-literals-2026-11-19.md) for `'0`/`'1` destination-width resolution at 2, 5, and 13 bits alongside the existing 4/8-bit cases, plus lowercase `'x` and uppercase `'Z` rejection.

## Vector SM-042 — rtl_unsized_decimal_context.sv

See rtl_unsized_decimal_context.expected.md and [RTL-005 conformance progress](../../../evidence/conformance/rtl-005-decimal-context-2026-11-19.md) for the initial literal-only vectors. The mixed, nested and bitwise fixtures extend evidence to selected arithmetic and bitwise expressions across continuous, `always_comb` and `always_ff` assignments. [Mixed-context evidence](../../../evidence/conformance/rtl-005-mixed-decimal-context-2026-11-19.md)

## Vector SM-009 — rtl_process_control_vectors.sv

See rtl_process_control_vectors.expected.md for nested priority if/else and exact case/default equations in complete-assignment always_comb processes. `test_process_control_oracle.ps1` checks T-IR source locations for each priority level and independently evaluates all 131072 input combinations, including both selects asserted together.

## Vector SM-010 — parameter_localparam_vectors.sv

See parameter_localparam_vectors.expected.md for default and overridden parameter configurations, localparam calculation, resolved port widths, and concatenation behavior.

## Vector SM-014 — parameterized_hierarchy_vectors.sv and port_expression_vectors.sv

See the adjacent expected-result files for recursively parameterized child interfaces and exact-width inference for concatenations, selects, fill literals, and sized literals. T015 records prototype observations; these do not establish T017 matrix conformance or expression lowering.

## Vector SM-016 — generate_instance_vectors.sv

See generate_instance_vectors.expected.md for active generate-if selection, inactive-branch exclusion, static generate-for instance expansion, stable paths, and genvar substitution in bit-select connections. T015 has build-level elaboration evidence; T017 and T-IR lowering remain open.

## Vector SM-029 — generated_scalar_instance.sv

See `generated_scalar_instance.expected.md`. `generated-scalar-instance.q3a` and `test_generated_instance_lowering.ps1` check an active generate-if with a nested one-iteration generate-for child instance, genvar-resolved parameter metadata, a hierarchical local signal, and flattened child equations. An unresolved module in the inactive branch must remain unelaborated. This vector does not cover generated assignments or output bit-select actuals.

## Vector SM-017 — sequential_case_vectors.sv

See sequential_case_vectors.expected.md for exact case matching inside `always_ff`, multi-label priority, hold behavior, and the last nonblocking assignment winning within one branch. `test_sequential_case.ps1` checks the TIR shape; `test_case_order_oracle.ps1` additionally verifies source mapping and compares all 32 input/state combinations with an independent next-state oracle.

## Vector SM-018 — casez_decode.sv

See casez_decode.expected.md. `test_casez_priority_oracle.ps1` exhaustively checks all 16 selector values against the independent truth table, including an overlapping wildcard case that verifies source-order first-match behavior.

## Vector SM-043 — casez_wildcard_positions.sv

See casez_wildcard_positions.expected.md and [RTL-027 conformance evidence](../results/t017-rtl027-casez-wildcard-positions-2026-11-20.md). The casez priority oracle checks every 4-bit selector value, three wildcard positions, exact T-IR masks and source locations, overlap priority, and default selection.

## Vector SM-019 — hierarchy_process_vectors.sv

See hierarchy_process_vectors.expected.md. `test_hierarchy_lowering.ps1` checks that one-level child `always_comb` logic flattens through named signal connections to the expected top-level equation.

## Vector SM-020 — hierarchy_expression_vectors.sv

See hierarchy_expression_vectors.expected.md. `test_hierarchy_lowering.ps1` checks substitution of an exact-width expression connected to a child input port.

## Vector SM-021 — hierarchy_internal_vectors.sv

See hierarchy_internal_vectors.expected.md. `test_hierarchy_lowering.ps1` checks a hierarchical child-local combinational signal and evaluates the flattened equations against the expected parent relation.

## Vector SM-022 — hierarchy_sequential_vectors.sv

See hierarchy_sequential_vectors.expected.md. `test_hierarchy_lowering.ps1` checks a one-clock child state transition, synchronous reset, and its connected parent output.

## Vector SM-023 — hierarchy_multiregister_vectors.sv

See hierarchy_multiregister_vectors.expected.md. `test_hierarchy_lowering.ps1` checks simultaneous updates to two child registers against all 16 state/input valuations.

## Vector SM-024 — multiple stateful child instances

See `hierarchy_sequential_vectors.expected.md`. `hierarchy-multiple-instances.q3a` instantiates one stateful leaf twice. `test_hierarchy_lowering.ps1` checks distinct hierarchical state names, separate output connections, and all 16 combinations of both states, reset, and enable.

## Vector SM-025 — nested combinational hierarchy

See `hierarchy_nested_vectors.expected.md`. `hierarchy-nested.q3a` checks two child levels, exact-width nested input expressions, a full hierarchical local-net path, and all 256 input pairs against the independent equality oracle.

## Vector SM-026 — nested sequential hierarchy

See `hierarchy_sequential_vectors.expected.md`. `hierarchy-nested-state.q3a` checks a stateful leaf through a middle-level module, including state path, clock aliasing, output mapping, and all eight transition valuations.

## Parameterized hierarchy lowering

See `parameterized_hierarchy_vectors.expected.md`. `test_hierarchy_lowering.ps1` lowers named and positional parameter overrides plus the default-parameter case, checks namespaced parameter metadata and exact signal widths at 2/3/4 bits, and exhaustively checks passthrough behavior for each configured width.

## Vector SM-027 — separate sequential processes

See `multi_process_vectors.expected.md`. `lower-multi-process.q3a` and `test_multi_process_transition_oracle.ps1` verify two `always_ff` processes on a shared clock and check all 16 simultaneous pre-edge transition cases.

## Vector SM-028 — contradictory BMC assumptions

`bmc-conflict.q3a` and `bmc_conflict.sv` declare both `a` and `!a` as same-sample assumptions. `test_result_bundle.ps1` confirms the feasibility query is preserved with `INCONSISTENT_MODEL_OR_ASSUMPTIONS`, the exact source/model identity is bundled, and the result is not reported as functional pass or fail.
## Vector SM-011 — case_order_vectors.sv

See case_order_vectors.expected.md for exact matching, default selection, and source-order behavior with duplicate matching items. `test_case_order_oracle.ps1` verifies source mapping and checks all four selector values against the first-match expected results.

## Vector SM-012/SM-013 — generate_boundary_vectors.sv

See generate_boundary_vectors.expected.md for zero/one/multiple static generate-for instances and nested generate-if selection.
## Negative RTL inputs

See negative-vectors/README.md for expected pre-proof diagnostics covering inferred latches, combinational cycles, multiple drivers, asynchronous reset, and unresolved module use. `test_process_control_oracle.ps1` independently checks the complete nested-if/exact-case RTL-020 source vector across all 131072 input combinations and verifies the source-located RTL-021 incomplete-assignment rejection. Other negative-vector diagnostics still require implementation/conformance evidence.

## Expected-model review rules

- The expected transition equations are authored independently from the RTL source and must be reviewed before they are used as conformance evidence.
- Every output includes a source-location mapping.
- Unsupported syntax is diagnosed before any property query.
- Record the source hash and the exact profile revision with each vector result.

## Terminology

| Abbreviation | Meaning |
|---|---|
| RTL | Register-transfer level |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |

## Vector SM-030 — generated_scalar_assignment.sv

See generated_scalar_assignment.expected.md. generated-scalar-assignment.q3a and test_generated_assignment_lowering.ps1 check active static generate-if/for whole-signal assignments, genvar substitution at the top and in a parameterized child, inactive-branch filtering, elaboration path reporting, and fail-closed generated declaration handling.

## Vector SM-031 — generated_bit_assignment.sv

See `generated_bit_assignment.expected.md`. `generated-bit-assignment.q3a` and `test_generated_bit_assignment_lowering.ps1` check complete generated bit-select and constant part-select assignment sets for descending and ascending packed ranges, parameterized child flattening, all 16 four-bit input values, a bounded SAT pass, a replay-validated false-property counterexample, and fail-closed diagnostics for incomplete, duplicate, conflicting, dynamic, out-of-range, and reversed-direction part-select targets.

## Vector SM-032 — generated_instance_output_bit.sv

See `generated_instance_output_bit.expected.md`. `generated-instance-output-bit.q3a` and `generated-instance-output-bit-ascending.q3a` exercise generated scalar child output ports connected to constant bit-selects of descending `[3:0]` and ascending `[0:3]` parent buses. `test_generated_bit_assignment_lowering.ps1` checks one complete bus equation per design, bounded SAT passes for both identity properties, replay of an intentionally false property, and rejection of partial, duplicate, whole-signal-conflicting, dynamic, out-of-range, and unsupported part-select connections. This vector covers direct-child mapping; nested-wrapper coverage is recorded under SM-033.

## Vector SM-033 — nested_instance_output_bit.sv

See `nested_instance_output_bit.expected.md`. `nested-instance-output-bit.q3a` exercises generated scalar wrappers whose outputs connect to individual bits of a top-level packed bus; each wrapper contains another child instance and a local signal. `test_generated_instance_lowering.ps1` checks that recursive flattening produces one complete four-bit bus equation and that `p_nested_output_map` returns `BOUNDED_PASS`. This is focused evidence for combinational direct and nested child output bit-selects, not general hierarchy conformance.

## Vector SM-034 — child_module_property.sv

See `child_module_property.expected.md`. `child-module-property.q3a`, `generated-child-property-bit.q3a`, `nested-child-module-property.q3a`, `generated-nested-child-property-bit.q3a`, and `test_child_property_lowering.ps1` check named and inline assertions, assumptions, and covers in direct, two-level nested, and three-level nested child instances, including generated scalar lanes whose outputs connect to packed parent bits. They verify recursively instance-qualified property names, clock/input/output alias substitution at each wrapper, namespace-safe history-data and `$past` guards, bounded passes, replay-validated false-property counterexamples, and assumptions that constrain a high-data cover to a bounded miss. The generated nested vector checks all 24 property paths and complete four-bit bus assembly in the same T-IR, then checks pass, guarded history, replayed failure, and assumption-constrained cover misses on all four lanes.

## Vector SM-035 — Sequential child output bit-selects

See `sequential_child_output_bit.expected.md`. `sequential-child-output-bit.q3a` and `nested-sequential-child-output-bit.q3a` exercise generated direct child state outputs and state outputs through a wrapper, each connected to one bit of a four-bit parent bus. `test_sequential_child_output_bit_lowering.ps1` checks four independent one-bit state equations per hierarchy, full-width bus assembly, guarded `$past` properties, bounded pass results, and replay-validated false-property counterexamples on all four lanes. This vector covers the focused scalar, constant bit-select subset; sequential part-select connections have separate direct/wrapped coverage in SM-037.

## Vector SM-036 — Scoped generate-local declarations

See `generated_scalar_declaration.expected.md`. The shared manifest and `test_generated_assignment_lowering.ps1` verify top-level generate-if declarations, same-named declarations in three generate-for iterations, full packed output-bit assembly, and one generated declaration inside a child module. The regression checks unique hierarchical signal names and corresponding T-IR equations, bounded SAT passes for the top and child relations, and fail-closed diagnostics for generated local parameters and unscoped declarations. This is focused evidence; it does not close general generate declaration conformance.

## Vector SM-037 — Sequential child output part-selects

See `sequential_child_output_part_select.expected.md`. `test_sequential_child_output_part_select_lowering.ps1` verifies two constant four-bit child output slices in direct and wrapper-nested hierarchy, for ascending `[0:7]` and descending `[7:0]` parent ranges. It checks complete eight-bit parent-bus assembly, correct/false guarded-history properties with independent replay, and width/direction/overlap/coverage rejection cases. This is focused evidence for the exact constant part-select subset.

## Vector SM-038 — Combinational child output part-selects

See `combinational_child_output_part_select.expected.md`. `test_combinational_child_output_part_select_lowering.ps1` checks direct and wrapper-nested four-bit combinational child outputs on both ascending `[0:7]` and descending `[7:0]` parent buses. Each lowers to a complete bus equation without residual proxies, and the bounded property checks the assembled XOR relation. This is focused evidence for combinational constant part-select connections in both packed-range directions.

## Vector SM-039 — RTL-017 constant-shift boundaries

See `rtl-017-shift-boundaries.expected.md` and [RTL-017 conformance evidence](../results/rtl-017-shift-boundaries-2026-11-19.md). `rtl-017-shift-boundaries.sv` checks left and right logical shifts for every four-bit unsigned operand value and every representable three-bit distance (0..7) against independent bit-concatenation and zero-fill references. `test_bmc_rtl_017_shifts.ps1` runs all 16 source properties through parsing, lowering, SAT, and nonvacuous frame-0 bounded checking. RTL-017 is Supported only for this bounded profile.

## Vector SM-040 — RTL-017 unsupported shift distances

See `rtl-017-unsupported-shifts.expected.md`. The dynamic and negative-distance source properties must produce source-located nonzero errors and no formal status. `test_bmc_rtl_017_unsupported_shifts.ps1` checks the CLI behavior. These expressions currently fail during selected-query bit-blasting, not during parsing/lowering.


## Vector SM-044 — sync_reset_isolation.sv

See sync_reset_isolation.expected.md and [RTL-023 conformance evidence](../results/t017-rtl023-sync-reset-isolation-2026-11-20.md). The independent oracle checks reset isolation from an unreset state element across all 16 old-state/input valuations and six held/released/reasserted frames, including exact source mappings.

## Vector SM-045 — rtl_sized_literal_resize.sv

See rtl_sized_literal_resize.expected.md and [RTL-006 conformance evidence](../results/t017-rtl006-sized-literal-conformance-2026-11-20.md). The vector checks signed and unsigned values for all four based integer bases, assignment zero/sign extension and truncation across continuous, always_comb, and always_ff paths, plus bounded SAT checks.

## Vector SM-046 — generate_branch_conformance.sv

See generate_branch_conformance.expected.md and [RTL-028 conformance evidence](../results/t017-rtl028-generate-if-conformance-2026-11-20.md). The vector checks outer/nested generate-if true and false selections across WIDTH/ENABLE configurations, 640 independent input pairs, exact source mapping, and bounded SAT assertions.

## Vector SM-047 — generate_for_count_conformance.sv

See generate_for_count_conformance.expected.md and [RTL-029 conformance evidence](../results/t017-rtl029-generate-for-conformance-2026-11-20.md). The vector checks exact static generate-for counts of 0, 1, and 3, stable generated scope names and declaration types, source mappings, nonvacuous count assertions, and a source-located nonadvancing-update rejection. Related SM-031 and SM-036 regressions cover generated bit/part-select assignments and repeated scoped declarations.

## Vector SM-048 — bmc_selects.sv

See bmc_selects.expected.md and [RTL-016 conformance evidence](../results/t017-rtl016-packed-select-conformance-2026-11-20.md). The vector checks ascending/descending packed ranges, direct constant bit/part selects, 2,304 independent numeric evaluations, source-mapped T-IR, nonvacuous BMC relations, replayed false properties, and fail-closed dynamic/out-of-range/reversed-direction selections.

## Vector SM-049 — rtl_unary_conformance.sv

See rtl_unary_conformance.expected.md and [RTL-010 conformance evidence](../results/t017-rtl010-unary-conformance-2026-11-20.md). The vector checks source-level unary `+`, `-`, `~`, and `!` on all 16 unsigned four-bit inputs, T-IR types/source mappings, nonvacuous bounded assertions, a replayed false property, and the separate exhaustive SAT unary-minus oracle.

## Vector SM-050 — bmc_mixed_width.sv

See bmc_mixed_width.expected.md and [RTL-011–RTL-014 conformance evidence](../results/t017-rtl011-014-mixed-width-conformance-2026-11-20.md). The vector provides source-level examples for unsigned comparisons/XOR, signed comparison/addition, and signed conditional extension; mixed-width SAT/replay regressions cover the bounded signedness and branch-value combinations.

## Vector SM-051 — bmc_cover_implication.sv

See bmc_cover_implication.expected.md and [SVA-004 conformance evidence](../results/t017-sva004-bounded-cover-conformance-2026-11-20.md). The vector checks overlapped/non-overlapped implication and sequence-antecedent cover witnesses, independent replay, and incomplete-bound UNKNOWN semantics. The supported scope is bounded reachability; it does not include IEEE vacuous-success coverage counters.

## Vector SM-052 — continuous_assignment_resize.sv

See continuous_assignment_resize.expected.md and [RTL-019 driver-ownership evidence](../results/rtl-019-continuous-driver-diagnostics-2026-11-19.md). The vector checks a legal sized-literal assignment truncation, explicit T-IR resize structure, source mapping, and a nonvacuous bounded result assertion. Exact-width port connections remain governed separately by RTL-002.

## Vector SM-053 — rtl-017-arithmetic-right-shift.sv

See `rtl-017-arithmetic-right-shift.expected.md` and the [extension evidence](../results/t017-rtl017-arithmetic-right-shift-extension-2026-11-20.md). The Phase 0 frontend rejects this candidate source vector before formal evaluation. SAT and replay unit oracles still exhaust all four-bit operand values for `>>` and `>>>`.

## RTL-005 decimal boundaries

See [expected decimal boundary results](rtl_unsized_decimal_boundaries.expected.md). The paired manifests exercise natural signed widths, underscores, exact-width port binding, narrow and wide targets, and a source-located rejection when the signed magnitude requires 65 bits.

The [nested arithmetic vector](rtl_unsized_decimal_nested_context.expected.md) checks width and signedness propagation through unary and binary arithmetic, comparison operands and a constant shift distance.
