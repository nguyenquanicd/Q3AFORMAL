# T013 Source Manager Implementation Evidence

**Date:** 2026-11-15  
**Profile:** Q3A-P0-R0.9.1  
**Scope:** Project manifest loading, source-boundary validation, source-byte SHA-256, and deterministic input hashing only.

## Build

- Target: Windows x64, C++17.
- Compiler: MinGW-w64 `g++.exe` 16.2.0.
- Command: `prototype/source/source_manager/build.ps1 -Compiler <g++.exe>`.
- Result: successful build to `prototype/bin/q3aformal-sourcecheck.exe` with `-Wall -Wextra -Wpedantic`; no compiler diagnostics were emitted.

## Checks

| Check | Result |
|---|---|
| Load `prototype/counter4.q3a` | Exit code 0; top `counter4_pass`; profile `Q3A-P0-R0.9.1`. |
| Source digest | `613b2dcefc6fbfaf977516ba71ded58d5596e611ce4f706d23a19b4afabfba5c` for `corpus/source-model-vectors/counter4_pass.sv`. |
| Project input digest | `8d9823be1d4496aa00dd3139450332bb51084e011d1b707dc70da7e8cbe2716a`. |
| Repeat identical invocation | Same project and source digests; output was byte-identical. |
| Relative source path containing spaces | Exit code 0; output path remained quoted and unambiguous. |
| Reject parent traversal in source path | Exit code 1 with `source path may not contain '..'`. |

## Interpretation

These checks establish that this build can load the sample manifest, produce repeatable source identities, preserve a spaced relative path, and reject a tested path traversal. They do not validate the RTL syntax or semantics, port widths, the SHA-256 implementation against a separate implementation, source-to-model translation, SAT results, or proof soundness. T015 and later tasks remain open.
