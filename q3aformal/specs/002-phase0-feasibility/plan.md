# Implementation Plan: Q3AFormal Phase 0 Feasibility Prototype

**Branch:** 002-phase0-feasibility  
**Specification:** specs/002-phase0-feasibility/spec.md  
**Status:** Phase 0 closed on 2026-11-24. The owner approved Gate B GO with C++17 and Deletion Resolution Asymmetric Tautology (DRAT).

This plan records the Phase 0 starting assumptions. See the [final decision and acceptance evidence](../../evidence/phase0-go-no-go.md) and the [Phase 1 implementation plan](../003-phase1-block-mvp/plan.md).

## Summary

Build a small, independently reviewable vertical slice under the owner-approved Gate A scope. The slice will exercise a tightly bounded RTL/SVA profile through parsing, elaboration, transition-system lowering, proof and witness generation, checking, replay, and result-bundle reopening. It must show a separate checked known-pass result and replay-validated known-fail result. Gate A has been recorded. Implementation proceeds only after the Stage B semantic corpus and model contract are reviewed.

## Technical Context

| Area | Current proposal | Owner status |
|---|---|---|
| Runtime dependencies | Q3A-owned components only, following the product specification | Approved approach |
| Implementation language/build | C++17 for the Phase 0 prototype; Gate B reviews whether to retain it | Selected |
| Target platform | Windows x64 development host; record exact host/compiler before measurement | Selected |
| RTL semantics | Owner-approved balanced subset: one-clock, two-valued, synchronous-reset; case/casez, static generate, exact operator matrix, exact-width module ports | Approved |
| SVA semantics | Single positive-edge clock, bounded repetition, guarded $past; disable iff/multi-clock/liveness rejected | Owner-approved balanced profile |
| SAT evidence | Evaluate a checkable proof format and a small independent checker | Format pending evidence review |
| Source-to-model evidence | Authored vectors, expected intermediate representations, bounded reference evaluation, metamorphic relations | Required |
| Benchmark thresholds | Must be agreed before measurement, never inferred after results | Pending |
| Tests | No implementation tests run yet; source vectors and expected-behavior artifacts are authored, while implementation evidence remains pending | Not applicable yet |

## Constitution Check

| Principle | Plan alignment |
|---|---|
| Scope every correctness claim | Results are limited to exact source/profile/model/assumptions recorded in the bundle. |
| Define semantics before claiming support | Every accepted construct needs a complete conformance-matrix row; otherwise reject it. |
| Require checkable evidence | PROVEN requires checked proof evidence; FAIL requires a replay-validated witness. |
| Preserve reproducibility and traceability | Source/model/query/build/checker identity and requirement-to-evidence mapping are required. |
| Keep review non-destructive | Original revision 0.8 remains a hash-identified snapshot; proposed changes stay under this feature folder. |
| No third-party runtime or oracle | No external parser, solver, formal engine, simulator, or model checker supplies runtime behavior or expected answers. |

**Gate A:** Owner approval was recorded on 2026-11-15 after the balanced subset was selected. Phase 0 work may proceed under this plan; numeric thresholds remain a pre-measurement gate.

## Architecture and Work Sequence

### Workstream A — Specification closure

1. Convert each review finding to a concrete proposal, owner decision, or bounded unresolved item.
2. Define reset timing using state-before-edge frames and reset-aware transitions at every active edge.
3. Separate literal categories and restrict unsupported language forms.
4. Specify SVA sampling, guarded $past history behavior, and explicit rejection of disable iff, unsupported history functions, multi-clock, and liveness forms.
5. Define source-to-model corpus and expected evidence independently from implementation.
6. Define result-bundle and cache identities for exact model, query, component build, and checker.

### Workstream B — Phase 0 prototype, after Gate A

1. Source manager and restricted parser/elaborator for the approved subset.
2. Typed elaborated representation and canonical transition-system intermediate representation.
3. One-clock transition relation including synchronous reset at every edge.
4. Bit-blasting, a Q3A-owned Boolean satisfiability solver, and proof artifact output.
5. Small, structurally separate artifact checker for both proof evidence and counterexample witnesses. The known-pass demonstration must check base and inductive-step obligations (or a complete invariant); finite bounded model checking alone cannot produce PROVEN.
6. Candidate-witness replay against the same transition model and assumptions.
7. Bundle writer/reader with model and evidence hashes.
8. Minimal command-line runner and machine-readable result summary.

The architecture is a vertical slice, not a complete ASIC formal tool. Graphical debugging, broad RTL/SVA conformance, partitioning, multi-clock support, and large-scale memory reasoning remain outside Phase 0.

### Alternatives considered

| Option | Advantages | Disadvantages | Recommendation |
|---|---|---|---|
| Build a complete frontend and engine before first end-to-end run | Establishes intended long-term architecture | High cost before evidence; large debugging surface; difficult to isolate semantic defects | Reject for Phase 0 |
| Use external tools as proof engines or correctness oracles | Fast prototype and broad language support | Violates the product dependency boundary and cannot establish Q3A-owned proof/evidence behavior | Reject |
| Implement a narrow Q3A-owned vertical slice with explicit rejection | Tests the critical trust chain early and limits semantics | Demonstrates feasibility only for a small subset; requires carefully authored reference evidence | Owner-approved |

## Data and Evidence Contracts

The prototype result bundle must bind:

- Source files, manifest, parameters, defines, and profile version.
- Exact canonical elaborated and transition model, schema version, and provenance map.
- Property binding, assumptions, reset and initialization policy, and exact proof query.
- Q3A release/build ID and relevant component/checker fingerprints.
- Proof or candidate-witness artifact and checker/replay report.
- Runtime and peak-memory observations, resource limits, and result status.
- Source/model integrity hashes and any historic-versus-current revalidation status.

A bounded miss is BOUNDED_PASS only. It cannot be promoted to PROVEN. A resource-limited or incomplete checker outcome is non-conclusive.

## Project Structure

Planning artifacts stay under q3aformal/specs/002-phase0-feasibility. The approved decision and benchmark records are under docs/phase0/. Implementation paths are:

- prototype/source/
- prototype/checker/
- prototype/corpus/
- evidence/ for Phase 0 bundles and benchmark report

**Structure decision:** Keep planning and evidence artifacts under q3aformal. Gate A is approved; implementation content may be added in the listed paths.

## Risk Controls

- **Semantic drift:** exact profile version and conformance rows travel with every run.
- **Correlated checker defects:** checker structure and implementation are separated; valid/invalid/malformed evidence is reviewed.
- **Misleading proof claims:** result status derives only from accepted evidence and complete procedures.
- **Vacuity:** contradiction and activation diagnostics report completeness, not just a Boolean warning.
- **Premature performance claims:** thresholds and hardware are approved before measurement.
- **Scope growth:** each new construct requires a new matrix row, evidence, and owner review.
- **Toolchain conflict:** C++17 is selected for Phase 0; capture compiler and host details before benchmark measurement.

## Decisions reviewed before Gate B

Gate B is closed. The decision register records the owner choices and the decision package records the corresponding evidence.

- C++17 is selected for Phase 0; decide at Gate B whether to retain it for the MVP.
- Windows x64 is selected as the Phase 0 host; record exact hardware/compiler details before measurement.
- Balanced Phase 0 RTL/SVA subset and reset policy are approved.
- Independently authored benchmark categories are approved; freeze source hashes, outcomes, and numeric thresholds before measurement.
- Q3A-owned runtime/no external proof oracle approach is approved.
- Evaluate DRAT first; choose the final proof-artifact format after evidence review.
- Set numeric runtime and memory thresholds before benchmark measurement.

## Terminology

| Abbreviation | Meaning |
|---|---|
| ASIC | Application-specific integrated circuit |
| IR | Intermediate representation |
| RTL | Register-transfer level |
| SAT | Boolean satisfiability |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |








