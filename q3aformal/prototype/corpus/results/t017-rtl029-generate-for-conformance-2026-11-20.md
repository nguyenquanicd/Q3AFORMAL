# T017 RTL-029 Static Generate-for Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-029, static `generate for`  
**Vector:** SM-047, `generate_for_count_conformance.sv`  
**Regressions:** `test_generate_for_conformance.ps1`, `test_generated_bit_assignment_lowering.ps1`, and `test_generated_assignment_lowering.ps1`

## Tested behavior

SM-047 resolves `COUNT` to 0, 1, and 3. The regression checks the exact scoped signal set (`none`, `g_items[0].present`, and `g_items[0..2].present`), internal one-bit types, the `is_one` equation source location, the clock-bound property mapping, and the elaborator's reported iteration count. A frame-0 assertion passes nonvacuously for all three configurations. A nonadvancing genvar update rejects with the expected source-located diagnostic before elaborated output is produced.

The existing SM-031 regression passed its independent ascending/descending bit- and part-select oracle, bounded SAT/replay checks, and fail-closed incomplete, duplicate, conflicting, dynamic, out-of-range, and reversed-direction target cases. The existing SM-036 regression passed its repeated scoped declaration checks across three loop iterations, packed-bus assembly, top/child bounded relations, and rejection of generated local parameters and unscoped declarations.

## Result

All three regressions passed on 2026-11-20. RTL-029 is **Supported for the tested static generate-for subset**: constant nonnegative iteration counts, stable named-block scope indices, the covered generated assignment targets, and the covered scoped `logic`/`bit` declarations.

## Limits

This does not establish complete SystemVerilog generate semantics. Dynamic bounds, generated local parameters, declaration initializers, unscoped generated declarations, unsupported generated types, and broader nested-genvar/source-provenance combinations remain outside the supported profile. A nonadvancing update is rejected; the regression does not claim exhaustive diagnostics for every malformed bound/update combination. T016/T017 remain open for the rest of the translation matrix.
