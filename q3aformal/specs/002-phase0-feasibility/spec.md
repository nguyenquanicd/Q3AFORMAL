# Feature Specification: Q3AFormal Phase 0 Feasibility Prototype

**Status:** Owner-approved Phase 0 scope; prototype plan ready  
**Feature ID:** 002-phase0-feasibility  
**Input specification:** Revision 0.8, snapshot SHA-256 EC3FDC69DE8B43BFDCD5DD6870CA9DC2F6FC09671F34354715DACA5503869A0D  
**Governance:** Gate A was approved by the owner on 2026-11-15 after the balanced RTL/SVA subset was selected. Phase 0 work is authorized within this scope; Gate B remains required before Phase 1.

## 1. Purpose

Define a small, reviewable Phase 0 prototype that can establish whether Q3AFormal's core claim is feasible: translate a tightly bounded synchronous register-transfer-level (RTL) and SystemVerilog Assertions (SVA) subset into a transition model, return a checked proof for a known-true property, and return a validated counterexample for a known-false property.

The current product specification contains material ambiguity in reset semantics, language support, proof evidence identity, and Phase 0 acceptance. This feature carries the approved closures into product specification revision 0.10 and the Phase 0 planning package. The original revision 0.8 remains preserved as an unchanged input snapshot.

## 2. Scope

### In scope

- Review and disposition the 11 findings in the existing specification analysis report.
- Specify the owner-approved balanced RTL/SVA profile and explicit rejection behavior.
- Define source-to-model conformance evidence and independent bounded evaluation.
- Plan a minimal vertical-slice prototype with separate known-pass and known-fail runs.
- Define result-bundle, proof-checker, cache-identity, benchmark, and owner-review evidence.
- Record Gate A decisions and author the conformance corpus before frontend/lowering implementation.

### Out of scope

- Initiating Phase 0 implementation without recorded Gate A authorization.
- Claiming full SystemVerilog or full SVA support from the Phase 0 subset.
- Changing the approved reset/profile/build decisions without owner review, or selecting final proof-format and numeric performance thresholds before the required evidence.
- Using third-party parsers, solvers, simulators, model checkers, or waveform tools as runtime dependencies or correctness oracles.
- Treating a checklist, analysis report, or prototype result as proof that all source-to-model translation is sound.

## 3. Functional Requirements

| ID | Requirement |
|---|---|
| Q3A-P0-FR-001 | Preserve the supplied revision 0.8 specification as a hash-identified snapshot and keep proposed edits separate until owner adoption. |
| Q3A-P0-FR-002 | Resolve each of the 11 documented specification findings with a concrete proposed clause, owner decision, or explicitly bounded open item. |
| Q3A-P0-FR-003 | Define a versioned Phase 0 RTL/SVA subset; reject unsupported or semantically incomplete constructs before proof. |
| Q3A-P0-FR-004 | Model synchronous reset in every transition frame and keep initial state unconstrained unless explicit initialization or assumptions constrain it. |
| Q3A-P0-FR-005 | Require a source-to-model corpus with reviewed expected elaborated representation, transition behavior, source mapping, and independently authored bounded reference evaluation for every prototype construct. |
| Q3A-P0-FR-006 | Require distinct known-pass and known-fail property runs. The pass run must have checker-accepted unbounded proof evidence, such as a one-inductive proof or checked invariant; finite bounded model checking alone is insufficient. The fail run must have a replay-validated witness. |
| Q3A-P0-FR-007 | Require the checker to process valid, single-defect invalid, and malformed proof artifacts with recorded expected verdicts. |
| Q3A-P0-FR-008 | Define a result bundle containing the exact canonical transition-system intermediate representation (T-IR), model provenance, query identity, evidence, and tool/component/checker fingerprints. |
| Q3A-P0-FR-009 | Define cache invalidation and revalidation rules that bind cached evidence to the exact model, query, profile, build, and checker identity. |
| Q3A-P0-FR-010 | Distinguish complete vacuity/contradiction findings from bounded or incomplete diagnostics. |
| Q3A-P0-FR-011 | Freeze the benchmark set, hardware profile, and resource thresholds before measuring runtime or memory. |
| Q3A-P0-FR-012 | Require Gate A approval before any Phase 0 prototype implementation and Gate B go/no-go review before Phase 1. |
| Q3A-P0-FR-013 | Keep owner decisions pending until explicitly resolved; proposed defaults must be labeled as proposals. |
| Q3A-P0-FR-014 | Maintain requirement-to-phase-to-acceptance traceability for the Phase 0 plan and proposed product-specification refinement. |

## 4. User Stories

### US1 — Review and freeze a small semantic contract

As the tool owner, I need a precise initial RTL/SVA profile, reset model, and unsupported-construct policy so that a prototype cannot silently prove behavior different from the source design.

**Acceptance:** Q3A-P0-FR-002, 003, 004, and 005 are addressed in reviewable artifacts; the selected subset is recorded, and any remaining semantic or evidence gaps are explicit.

### US2 — Demonstrate proof and counterexample paths

As a verification engineer, I need one known-true property proved with checkable evidence and one known-false property returned with a replay-validated trace so that the prototype demonstrates both conclusive result paths.

**Acceptance:** The two outcomes are produced by separate runs. The known-pass result includes checker-accepted induction/invariant evidence, never only a finite bound; the known-fail result includes a replay-validated witness.

### US3 — Reopen and trust the saved evidence

As a reviewer, I need each result bundle to identify the exact transition model, query, assumptions, build, and checker so that a saved result cannot be mistaken for evidence about a different model or executable.

**Acceptance:** Q3A-P0-FR-008 and 009 are met; unavailable or incompatible checkers cause a historic/unverified label.

### US4 — Make an evidence-based investment decision

As the tool owner, I need a benchmark report, documented open decisions, and a clear Gate B recommendation so that Phase 1 is approved only after the feasibility evidence is reviewed.

**Acceptance:** Q3A-P0-FR-010 through 014 are met; no unmeasured performance claim is made.

## 5. Edge Cases

- Synchronous reset stays asserted across several active edges or is asserted again after release.
- No reset is assumed at startup; resettable and non-resettable state begin unconstrained unless explicitly constrained.
- Initial assumptions are contradictory or a frame-local environment constraint is inconsistent.
- A property antecedent is not observed within a bounded search, but no complete reachability proof exists.
- An RTL or SVA construct parses but has no reviewed lowering or semantic evidence.
- A proof bundle is reopened with a changed source tree, model, schema, or checker.
- A proof artifact is malformed or contains one altered clause/literal.
- A bounded run finds no counterexample; this must not be labeled PROVEN.
- An unsupported asynchronous reset, disable iff, sampled-value history function, or multi-clock property is encountered.
- Resource thresholds have not been approved before a benchmark run.

## 6. Success Criteria

| ID | Measurable success criterion |
|---|---|
| Q3A-P0-SC-01 | The revision 0.8 snapshot matches its recorded SHA-256 and remains unchanged; revision 0.10 records the approved updates. |
| Q3A-P0-SC-02 | All 11 review findings map to a proposed resolution or a named owner decision. |
| Q3A-P0-SC-03 | Every planned Phase 0 requirement maps to at least one task and one acceptance criterion. |
| Q3A-P0-SC-04 | Analysis reports separate source/model scope, incomplete diagnostics, and owner-pending decisions. |
| Q3A-P0-SC-05 | No engine implementation begins before the owner records Gate A approval. |
| Q3A-P0-SC-06 | Gate B requires independent evidence for one PROVEN run with checked unbounded induction/invariant obligations and a separate FAIL run, plus checker, source-to-model, bundle, and benchmark evidence. |

## 7. Owner Decisions Recorded at Gate A

The following decisions were recorded on 2026-11-15. Numeric measurement thresholds remain a pre-measurement gate:

1. C++17 is selected for the Phase 0 prototype; retaining it for the MVP will be reviewed at Gate B.
2. Windows x64 is selected as the Phase 0 development host; exact hardware/compiler details will be captured before benchmark measurement.
3. The owner approved the balanced Phase 0 subset, synchronous-reset/initial-state contract, exact-width module-port rule, and positive repetition bounds; port-width mismatches and zero-bound repetition are rejected. The owner also approved positive repetition bounds; exact zero-count and zero-minimum forms are rejected.
4. Use independently authored Q3A benchmark designs with expected outcomes and recorded provenance.
5. Follow the product's self-contained runtime dependency boundary.
6. Evaluate DRAT as the first proof-artifact candidate; select the final format at Gate B.
7. Set numeric time and memory thresholds before the first benchmark measurement.

## 8. Terminology

| Abbreviation | Meaning |
|---|---|
| ASIC | Application-specific integrated circuit |
| IR | Intermediate representation |
| RTL | Register-transfer level |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |










