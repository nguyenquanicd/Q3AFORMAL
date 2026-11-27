# T014 Lexer and Parser Implementation Evidence

**Date:** 2026-11-15  
**Profile:** Q3A-P0-R0.9.1  
**Scope:** Source-located lexical and syntax validation for the Phase 0 corpus. This does not establish semantic elaboration or formal proof support.

## Build

- Target: Windows x64, C++17.
- Compiler: MinGW-w64 `g++.exe` 16.2.0.
- Build script: `prototype/source/source_manager/build.ps1`.
- Result: successful build with `-Wall -Wextra -Wpedantic`; no compiler diagnostics were emitted.

## Positive syntax corpus

`prototype/supported-parse.q3a` was parsed with `q3aformal-sourcecheck --parse-project`. It lists 13 source files covering declarations, literals, expressions, assignments, procedural control, case/casez, static generate, hierarchy instances, and SVA. Result: exit code 0, profile `Q3A-P0-R0.9.1`, input SHA-256 `2f2569937209721570979244aa73e7c1c528e1ccd2c11f28e96b1fa458140bec`, and 16 module declarations reported.

## Boundary cases

| Input | Expected parser outcome | Observed result |
|---|---|---|
| `sva_zero_repetition_reject.sv` | Reject zero repetition bounds | Exit 1; source-located positive-bound diagnostic. |
| `asynchronous_reset_reject.sv` | Reject asynchronous event control | Exit 1; rejected the extra event term after `posedge`. |
| `unsupported_multiplier_reject.sv` | Reject `*` operator | Exit 1; operator-located unsupported-subset diagnostic. |
| `xz_literal_reject.sv` | Reject X/Z data literal | Exit 1; literal-located two-state-profile diagnostic. |
| `latch_inference_reject.sv` | Parse syntax; semantic pass must detect latch | Exit 0. |
| `multiple_driver_reject.sv` | Parse syntax; driver analysis must reject | Exit 0. |
| `unresolved_module_reject.sv` | Parse syntax; hierarchy elaboration must reject | Exit 0. |
| `port_width_mismatch_reject.sv` | Parse syntax; elaboration must reject width mismatch | Exit 0. |
| `invalid_named_port_reject.sv` | Parse syntax; hierarchy elaboration must reject port name | Exit 0. |
| `out_of_range_select_reject.sv` | Parse syntax; elaboration must reject select bounds | Exit 0. |

All 10 boundary outcomes matched their parser-stage expectation. The six syntax-valid negative designs are not accepted as valid RTL; their intended rejection belongs to later semantic/elaboration checks.

During corpus review, `parameter_localparam_vectors.sv` was found to use multiplication even though Phase 0 rejects `*`. The equivalent width expression was changed from `2*WIDTH` to `WIDTH+WIDTH`, preserving the expected widths while keeping the corpus inside the approved operator profile. No product-specification scope was changed.

## Known boundary

The parser validates syntax and retains token spans for module regions. It does not produce a typed abstract syntax tree or resolve names, parameters, widths, drivers, latch completeness, generate conditions, or SVA constant bounds. The conformance matrix remains `Planned`; T017 must compare implementation behavior with the complete reviewed vectors before any row is marked `Supported`.
