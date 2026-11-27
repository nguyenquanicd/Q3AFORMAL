# T017 RTL-002 Hierarchy Port Diagnostic Evidence

**Date:** 2026-11-19  
**Regression:** `prototype/tests/test_hierarchy_lowering.ps1`

## Positive cases

The regression lowers named and positional port connections, plus default/overridden parameterized hierarchy. It checks the resulting T-IR connections, widths, and representative values. The regression passed on 2026-11-19.

## Required rejection cases

The regression invokes `--elaborate-project` for each invalid project and requires exit code 1 with the expected diagnostic and the corresponding source file plus numeric line and column before T-IR generation:

| Project | Expected diagnostic content |
|---|---|
| `hierarchy-width-mismatch.q3a` | Actual `narrow_data` is 4 bits; formal `data_in` is 8 bits; exact widths are required. |
| `hierarchy-invalid-port.q3a` | Instance `u_compare` references unknown port `invalid_port`. |
| `unresolved-module.q3a` | Instance references unresolved module `phase0_missing_child`. |
| `recursive-instance.q3a` | Recursive module instantiation is detected at instance `u_recurse`. |
| `hierarchy-missing-top.q3a` | `hierarchy_missing_top` is absent; diagnostic points to `hierarchy_vectors.sv:1:1`. |

The direct missing-top result is:

```text
Q3A_ELABORATION_ERROR corpus/source-model-vectors/hierarchy_vectors.sv:1:1: top module 'hierarchy_missing_top' was not found in the source set
```

## Scope

This closes the matrix's named/positional exact-width port-resolution criterion and its listed negative diagnostics. It does not establish complete hierarchy source-to-T-IR equivalence, arbitrary child output expressions, or broader selected-output boundaries. T016/T017 remain open.
