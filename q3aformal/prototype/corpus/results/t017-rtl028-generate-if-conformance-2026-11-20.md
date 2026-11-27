# T017 RTL-028 Static Generate-If Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** RTL-028, static `generate if`  
**Vector:** SM-046, `generate_branch_conformance.sv`  
**Regression:** `prototype/tests/test_generate_if_conformance.ps1`

## Method

Four parameter configurations exercise both choices of the outer `ENABLE` branch and both choices of the nested `WIDTH == 4` branch. The regression checks resolved parameter values, selected/elided generate paths, active equation type, exact assignment source location, and clock-bound source assertion.

An independent T-IR evaluator checks every input pair for the four configurations (640 combinations total). Each configuration also runs a bounded Boolean assertion at frame 0 and must pass nonvacuously. Existing SM-036 evidence checks scoped declarations in active generate-if/for blocks and rejects unsupported generated declaration forms.

## Result

```text
PASS: nested static generate-if true/false selection, parameters, source mappings, 640 independent input pairs, and four nonvacuous bounded assertions match the expected behavior.
```

The regression passed on 2026-11-20 with exit code 0. RTL-028 is Supported for the tested nested static-condition profile.

## Scope and limits

Generate conditions must resolve at elaboration time. Runtime conditions are rejected. This evidence does not establish complete SystemVerilog generate scoping/type semantics; generate-local parameters, declaration initializers, and unscoped declarations remain unsupported.
