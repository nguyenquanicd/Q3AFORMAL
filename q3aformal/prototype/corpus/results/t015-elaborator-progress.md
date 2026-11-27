# T015 Elaborator Implementation Evidence

**Date:** 2026-11-15  
**Profile:** Q3A-P0-R0.9.1  
**Status:** T015 implementation task complete for the current Phase 0 prototype subset. T017 matrix conformance remains open. This report does not claim complete SystemVerilog elaboration, transition-model generation, or formal proof.

## Implemented behavior

- Resolves typed top-level parameters and localparams, including supported integer/logic/bit constant expressions and parameter overrides.
- Computes packed widths for top-level ports and signals.
- Resolves static generate-if selection and generate-for iteration values/counts, with a prototype iteration safety limit and a non-advancing update diagnostic.
- Records module instances, named/positional parameter overrides, and named/positional port connections.
- Recursively resolves non-generate child parameter values from defaults or parent-scope overrides, then constructs typed child parameter/localparam/port/signal metadata and checks each level's direct connections.
- Infers exact widths for supported port actuals including identifiers, sized/fill literals, bit/part selects, concatenations, unary/binary operators, and conditional expressions.
- Resolves active module instances inside selected static generate branches and each unrolled static generate-for iteration; inactive branches are not elaborated. Genvar values are substituted into generated instance paths and connection expressions.
- Rejects unresolved/duplicate child module declarations, duplicate instance names, recursive module instantiation, mixed named/positional connections, unknown or missing named ports, incorrect positional port counts, undeclared actual signals, unsupported non-identifier actual expressions, and connected-width mismatches.
- Enforces the owner-selected exact-width rule throughout the implemented non-generate hierarchy; no implicit resizing is applied.

## Build and observed vectors

Built the combined executable on Windows x64 with MinGW-w64 `g++.exe` 16.2.0 using the checked-in C++17 build script and warning flags `-Wall -Wextra -Wpedantic`. The build completed successfully without compiler diagnostics.

| Project/vector | Expected result | Observed result |
|---|---|---|
| `prototype/param-default.q3a` | WIDTH defaults to 4; dependent widths resolve to 4 and 8 | Exit 0; reported `WIDTH=4`, `DOUBLE_WIDTH=8`, and widths 4/8/1 |
| `prototype/param-width3.q3a` | WIDTH override resolves dependent widths to 3 and 6 | Exit 0; reported `WIDTH=3`, `DOUBLE_WIDTH=6`, and widths 3/6/1 |
| `prototype/gen-count0.q3a`, `gen-count1.q3a`, `gen-count3.q3a` | Static loop counts 0, 1, and 3 | Previously observed as 0, 1, and 3 generated iterations respectively |
| `prototype/gen-width4.q3a`, `gen-width3.q3a`, `gen-disabled.q3a` | Resolve selected branches, generated paths, and parameterized widths | Previously observed correct branch choices and loop counts 3, 2, and zero for the disabled nested path |
| `prototype/parameterized-hierarchy.q3a` | Pass WIDTH=4 through two child hierarchy levels and match each port width | Exit 0; `u_leaf` and `u_leaf.u_passthrough` report matching width 4 connections |
| `prototype/parameterized-hierarchy-width3.q3a` | Pass top override WIDTH=3 through two child hierarchy levels | Exit 0; both child levels report matching width 3 connections |
| `prototype/parameterized-hierarchy-positional.q3a` | Apply a positional child parameter override at both hierarchy levels | Exit 0; child parameter values and connections resolve to width 4 |
| `prototype/parameterized-hierarchy-default.q3a` | Use child parameter defaults without instance overrides | Exit 0; both child levels resolve to width 2 |
| `prototype/port-expressions.q3a` | Check concat of part-selects, context-sized `'0`, sized literal, and signal actuals | Exit 0; all actual expression widths match their four-bit formals |
| `prototype/generated-hierarchy.q3a` | Select `ENABLE=1`, skip inactive missing module, and instantiate one conditional child plus four loop children | Exit 0; paths `g_enabled.u_flag` and `g_bits[0..3].u_bit`, with generated indices substituted into actual expressions |
| `prototype/generated-hierarchy-disabled.q3a` | Select `ENABLE=0` branch containing an unresolved child | Exit 1; source-located unresolved-module diagnostic for the selected branch |
| `prototype/hierarchy-named.q3a` | Accept all named direct-child connections | Exit 0; three connections reported at widths 4, 4, and 1 |
| `prototype/hierarchy-positional.q3a` | Accept all positional direct-child connections | Exit 0; three connections reported at widths 4, 4, and 1 |
| `prototype/hierarchy-width-mismatch.q3a` | Reject 4-bit actual to 8-bit child formal | Exit 1; source-located exact-width diagnostic reports actual/formal widths |
| `prototype/hierarchy-invalid-port.q3a` | Reject unknown named port | Exit 1; source-located diagnostic identifies `invalid_port` |
| `prototype/unresolved-module.q3a` | Reject an unresolved child module | Exit 1; source-located diagnostic names `phase0_missing_child` |
| `prototype/recursive-instance.q3a` | Reject a module recursively instantiating itself | Exit 1; source-located recursive-instantiation diagnostic |
| `prototype/nonterminating-gen.q3a` | Reject a generate update that does not advance | Exit 1; source-located diagnostic identifies the non-advancing update |

The parameterized-child vector and expected behavior are kept in `prototype/corpus/source-model-vectors/parameterized_hierarchy_vectors.sv` and its adjacent expected-result file. The hierarchy smoke manifests are under `prototype/`.

The final T015 build reran `prototype/supported-parse.q3a`: all 13 source files parsed and 16 module declarations were reported. The focused elaboration run checked 21 positive/negative project outcomes across parameter, generate, named/positional hierarchy, recursive parameter overrides, expression widths, generated instances, and rejection cases; every observed exit code matched its expected result.

## Remaining T015 work and boundaries

- Complete expression width, signedness, context-sizing, and select-bound semantics for every accepted Phase 0 expression.
- Materialize generated declarations and assignments into the transition model; T016 owns RTL/SVA lowering.
- Complete type/sign conversion and parameter-boundary conformance against the full accepted matrix; currently constant evaluation uses signed 64-bit intermediates and typed constants are capped at 64 bits in this prototype.
- Add implementation evidence for all matrix boundary cases and independent expected-model comparisons under T017.

The prototype iteration safety limit (1,000,000) and scalar constant bounds are implementation guards, not approved product-specification limits. Full T016 RTL/SVA-to-T-IR lowering, T017 conformance, all SAT/proof/checker/replay tasks, and final completeness evidence remain open; an initial continuous-assignment T-IR slice is tracked separately in `t016-lowering-progress.md`.
