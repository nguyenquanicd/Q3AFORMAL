# Requirements Quality Checklist: Q3AFormal Technical Specification

**Purpose**: Evaluate completeness, semantic precision, consistency, traceability, and acceptance readiness of the Q3AFormal RTL formal-verification specification.
**Created**: 2026-11-15
**Feature**: [spec.md](../spec.md)

**Note**: Generated using the Spec Kit `$speckit-checklist` requirements-quality workflow. This assesses specification quality, not implementation correctness.
**Review Ownership**: The user requested this assessment. `[x]` means the criterion is satisfied by the written specification; `[ ]` means a gap, ambiguity, or open decision remains.
**Marker Semantics**: A checked item is not evidence that Q3AFormal has been implemented or validated.

## Scope and Acceptance

- [x] CHK001 The product scope distinguishes the supported RTL/SVA model from unrestricted SystemVerilog/SVA and requires unsupported constructs to be rejected.
- [x] CHK002 The specification identifies major out-of-scope areas, including general testbench simulation, multi-clock semantics, and four-valued MVP logic.
- [ ] CHK003 MVP performance, memory, design-size, and trace-navigation acceptance targets are numeric and fixed before measurements are evaluated. **OPEN**: targets are deferred to Phase 0/owner approval.
- [ ] CHK004 Each functional requirement maps explicitly to a roadmap phase and named acceptance test/evidence artifact. The specification requires traceability but does not provide the matrix.

## RTL and SVA Semantics

- [ ] CHK005 Synchronous reset behavior is defined consistently in both the initial-state set and every transition frame, including reset held or reasserted after startup. **FAIL**: §7.2 models reset as an initial-state constraint while also calling it synchronous and requiring reset-held cases.
- [ ] CHK006 Unsized decimal, unsized based, and unbased unsized literals have distinct, non-conflicting width and signedness rules. **FAIL**: `'1` is classified both as a context-sized signed number and as a context-filling literal.
- [ ] CHK007 Every RTL construct called supported has a closed syntax subset and exact behavior for processes, assignment ordering, arrays, case forms, functions/tasks, interfaces, and preprocessing. **PARTIAL**: several entries use terms such as “where defined,” “selected,” or “within backend capability.”
- [ ] CHK008 Concurrent assertion sampling, `disable iff`, and first-sample behavior precisely match the declared SVA profile or are explicitly defined as a restricted profile. **PARTIAL**: asynchronous disable behavior and the source of `$past` defaults need exact rules.
- [x] CHK009 Uninitialized registers are not silently initialized to a convenient constant; the proposed policy treats them as unconstrained.
- [x] CHK010 Assumption placement is stated for BMC, k-induction, and PDR, with assumption identity included in proof evidence.

## Proof Claims and Trust Boundaries

- [x] CHK011 Result statuses distinguish a finite bounded pass from an unbounded proof and distinguish incomplete/resource-limited outcomes.
- [x] CHK012 FAIL, PROVEN, COVERED, and UNREACHABLE have separate evidence requirements and validation boundaries.
- [ ] CHK013 The source-to-model validation method has objective acceptance criteria beyond naming the frontend/lowering as trusted and requiring conformance/metamorphic testing. **PARTIAL**: corpus construction and release evidence are not specified.
- [x] CHK014 The proof and invariant checkers have explicit valid, single-defect invalid, and malformed artifact test classes.

## Results, Cache, and Traceability

- [ ] CHK015 A saved result bundle always contains, or can deterministically reconstruct, the exact model and artifacts required to revalidate its proof/witness. **PARTIAL**: the source snapshot is optional, while the exact T-IR/model artifact is not listed in the bundle layout.
- [ ] CHK016 Cache identity includes the Q3A build/component versions, checker version, and exact lowered-model identity needed to prevent reuse across implementation changes. **PARTIAL**: the current list includes semantic/schema versions and CNF or bit-blaster configuration but not these identities explicitly.
- [x] CHK017 VCD import/export distinguishes formal evidence from external display-only traces and defines X/Z handling and round-trip behavior.
- [ ] CHK018 GUI and large-trace performance criteria have measurable thresholds tied to an agreed hardware profile before MVP acceptance. **OPEN**: measurements and targets are deferred.

## Document Consistency and Readiness

- [ ] CHK019 Section references point to the actual section numbering and existing anchors. **FAIL**: multiple references point to stale or nonexistent subsection numbers.
- [x] CHK020 Owner decisions and a Phase 0 go/no-go gate are explicitly called out.
- [ ] CHK021 Phase 0 acceptance separates a known-good proof artifact from a known-failing validated witness, without implying both arise from the same assertion/run.
- [ ] CHK022 Contradictory-assumption and vacuity checks define which cases are guaranteed detections and which are best-effort warnings or known limitations.

## Notes

- The related detailed findings and recommended resolutions are in [SPECIFICATION_ANALYSIS_REPORT.md](../SPECIFICATION_ANALYSIS_REPORT.md).
- Source snapshot: [Q3AFORMAL_SPECIFICATION.md](../inputs/Q3AFORMAL_SPECIFICATION.md).
- Nine criteria are satisfied; thirteen remain open, partial, or failed. This is a specification review status, not an implementation test result.

