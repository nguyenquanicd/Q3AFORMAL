# T017 RTL-001 Missing-Top Diagnostic Evidence

**Date:** 2026-11-19  
**Regression:** `prototype/tests/test_hierarchy_lowering.ps1`

## Vector

`prototype/hierarchy-missing-top.q3a` selects `hierarchy_missing_top`, while its source file declares the valid hierarchy from `hierarchy_vectors.sv` under other module names. The elaborator must reject the project before lowering or any formal query.

## Result

Direct command:

```text
Q3A_ELABORATION_ERROR corpus/source-model-vectors/hierarchy_vectors.sv:1:1: top module 'hierarchy_missing_top' was not found in the source set
```

Exit code: `1`. The hierarchy regression now checks this exact source path, line, column, missing top name, and failure phase; the test passed on 2026-11-19. Existing positive named, positional, nested, parameterized, and generated hierarchy checks in the same regression also passed.

This closes the missing-top diagnostic criterion for RTL-001 only. It does not close RTL-002 hierarchy boundary cases or complete T016/T017 source-to-T-IR conformance.
