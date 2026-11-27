# Q3AFormal Specification Analysis Report

**Reviewed document**: `Q3AFORMAL_SPECIFICATION.md`  
**Revision**: 0.8  
**Assessment date**: 2026-11-15  
**Source SHA-256**: `EC3FDC69DE8B43BFDCD5DD6870CA9DC2F6FC09671F34354715DACA5503869A0D`  
**Method**: Spec Kit `speckit-checklist` requirements-quality workflow, adapted to a hardware formal-verification technical specification.  
**Input status**: Read-only; the source file was not changed.

## Executive Assessment

Revision 0.8 is a strong basis for Phase 0. It clearly bounds proof claims to the elaborated transition model and assumptions, distinguishes bounded from unbounded results, defines a conservative result-status taxonomy, separates witness checking from proof checking, and recognizes the frontend and lowering as part of the trusted computing base. The no-third-party-runtime boundary and the go/no-go feasibility gate are also explicit.

The specification is **not ready to freeze the MVP semantic profile**. One reset-model ambiguity can change the behavior being proved. Several language rules that are presented as concrete still need exact definitions. The archive/cache contracts also need to preserve the precise model and implementation identity that a result depends on.

The checklist has 22 criteria: **9 satisfied; 13 partial, failed, or pending**. Findings: **1 Critical, 6 High, 4 Medium**. These are specification findings; no RTL implementation, proof engine, or benchmark was executed.

## Spec Kit Workflow Note

Spec Kit was initialized in the requested `q3aformal` output directory and its bundled requirements-quality checklist workflow was applied to the supplied document. Spec Kit's separate `$speckit-analyze` command is a read-only cross-artifact check that requires `spec.md`, `plan.md`, and a complete `tasks.md` after task generation. This request is a single-document specification assessment, not an implementation-planning exercise, so no artificial product task list was created and `$speckit-analyze` was not invoked.

## Findings

| ID | Severity | Location | Finding | Recommended resolution |
|---|---|---|---|---|
| Q3A-SPEC-001 | **CRITICAL** | §7.2; §5.3; reset acceptance cases | The MVP calls reset synchronous but models it as an initial-state constraint that adds no reset transition frames. The text does not clearly prohibit reset from remaining asserted or being reasserted after startup, and it requires a reset-held acceptance case. A model that ignores later synchronous reset edges may prove a different behavior from the RTL. | Choose one contract: include reset in `T` at every active clock edge, or formally restrict the profile to a one-time startup reset and prove/document that restriction. Define cycle numbering, reset sampling, property disabling, and reset-held/reasserted behavior together. |
| Q3A-SPEC-002 | **HIGH** | §14.1.1, unsized literals | `'1` is listed both as a signed, context-sized unsized number and as an unbased unsized fill literal. Those descriptions conflict: the latter fills the receiving context with ones. Grouping all unsized numeric forms under one sizing/signedness rule risks incorrect bit-blasting. | Specify separate rows for unsized decimal literals, unsized based literals, and unbased unsized fill literals, including width, signedness, extension, truncation, and rejected X/Z cases. Add boundary tests for each category. |
| Q3A-SPEC-003 | **HIGH** | §14.1.2–§14.1.3 | The claimed RTL profile still contains open-ended terms such as “`always` where its synthesizable semantics are defined,” “selected `struct`/`union`,” and “an interface subset.” It does not yet close process scheduling/assignment ordering, incomplete combinational assignments, case variants, preprocessing, function/task limits, or interface constructs. The conformance matrix is a future deliverable, so the supported surface is not yet frozen by this document. | Enumerate the exact syntax and semantic rules for the MVP, including explicit reject rules. Avoid a construct being called supported until its matrix row and positive/negative semantic tests are complete. |
| Q3A-SPEC-004 | **HIGH** | §14.2.1–§14.2.3 | SVA sampling is described, but `disable iff` is phrased as a condition true “at a sampled point” without saying whether the profile implements SystemVerilog's asynchronous abort behavior or a deliberately restricted synchronous interpretation. `$past` first-sample defaults are also not tied to an exact source-language form or initialization policy. | Define the supported `disable iff` timing semantics and `$past` overload/default rules precisely. If the MVP intentionally narrows standard semantics, label the restriction in the profile and reject unsupported forms. |
| Q3A-SPEC-005 | **HIGH** | §10.3; §15.3; §16.1; §17 | The specification correctly says the proof checker does not certify RTL-to-T-IR translation and lists the frontend/lowering in the trusted computing base. However, “conformance suites, source-to-model checks, and metamorphic tests” are not yet turned into a concrete, reviewable acceptance method, especially under the rule that external formal tools are not test oracles. | Define an independently authored source-to-model corpus, expected T-IR/transition behavior, metamorphic transformations, and a Phase 0 acceptance record. Include small cases that can be exhaustively checked by a separately structured Q3A reference evaluator. |
| Q3A-SPEC-006 | **HIGH** | §10.3; §13.3 | The result bundle claims that `PROVEN`, `FAIL`, and `COVERED` results can be reopened from the bundle alone, but the listed layout does not explicitly include the exact lowered model/provenance needed to revalidate evidence. The source snapshot is optional. This leaves the “bundle alone” guarantee underspecified. | Either require a hash-verified source snapshot plus the exact tool/profile versions needed to regenerate the model, or include a versioned, integrity-checked model artifact and all evidence needed for independent revalidation. State how each status is reopened. |
| Q3A-SPEC-007 | **HIGH** | §11.3; Q3AF-FR-036 | The cache key includes source/configuration and semantic/schema information, but does not explicitly include the Q3A build or relevant component/checker versions and exact lowered-model identity. The alternative “bit-blaster configuration” is not necessarily enough to distinguish a corrected implementation that uses the same configuration. | Include a build/component fingerprint and exact E-IR/T-IR and generated-query identities in cache validation. Define invalidation after semantic, lowering, solver, or checker fixes. Recheck cached proof artifacts with the current checker before reporting them as conclusive. |
| Q3A-SPEC-008 | **MEDIUM** | §§2, 5.3, 7.2, 8, 14.2–§17 | Several section references are stale or point to nonexistent subsections: §2 and §17.1 refer to Phase 0 as §16.1, while the actual roadmap subsection is numbered §15.1; §17.6 is cited for vacuity although §17 is a flat acceptance list; §18.2 and §18.8 are cited for owner decisions although these are list items 2 and 8; §15.2.2/§15.3 references point to language-profile subsections numbered §14.2.2/§14.3. | Renumber the language-profile and roadmap subsections consistently, then validate every `§N.N` reference against the actual heading tree. Replace references to list items with “Owner decision 2” or the corresponding criterion ID. |
| Q3A-SPEC-009 | **MEDIUM** | §§14, 16–17 | The document states that every FR must trace to implementation and acceptance evidence, but no explicit FR-to-roadmap-phase-to-test/evidence matrix is included. The acceptance criteria cover major themes but do not identify coverage for every one of the 39 FRs. | Add a compact traceability table with `FR ID → phase → acceptance/test ID → evidence artifact`; identify intentionally deferred requirements and the release phase that closes them. |
| Q3A-SPEC-010 | **MEDIUM** | §16.1, Phase 0 exit criterion 2 | The phrase “one assertion is demonstrated end-to-end with a validated witness and a checked proof artifact” can be read as requiring the same property/run to both fail with a witness and prove successfully. Those are different outcomes. | Require at least one known-pass run with a checked proof artifact and one known-fail run with a validated witness, or explicitly state the intended alternatives. |
| Q3A-SPEC-011 | **MEDIUM** | §§5.3, 14 Q3AF-FR-012, 17 criterion 6 | Vacuity and contradictory-assumption behavior shifts between “detect or warn where it can establish,” a functional requirement to provide checks, and an acceptance criterion that permits a known limitation. The guaranteed detection boundary is unclear. | Define the guaranteed checks (for example, contradictory assumptions at a frame, initial-state inconsistency, unreachable activation within a bound) and label heuristic or incomplete checks as warnings. State what evidence is recorded in the run bundle. |

## Strengths to Preserve

- Formal results are explicitly scoped to the elaborated transition model and recorded assumptions.
- `BOUNDED_PASS` is not conflated with `PROVEN`; timeout, resource limit, cancellation, unsupported input, and engine errors have separate statuses.
- Witness validation and proof/invariant checking have separate contracts and test corpora.
- The frontend, lowering, and bit-blaster are acknowledged as trusted components rather than implicitly “certified” by the proof checker.
- The specification requires unsupported constructs to fail explicitly and restricts the MVP to a two-valued, single-clock profile.
- The no-third-party runtime boundary, source provenance, result reproducibility, and Phase 0 go/no-go decision are stated.

## Recommended Closure Order

1. Resolve Q3A-SPEC-001 before freezing reset, assumptions, or SVA semantics.
2. Close Q3A-SPEC-002 through Q3A-SPEC-004 and publish the actual RTL/SVA conformance matrix.
3. Define the independent source-to-model acceptance corpus and the archive/cache identity contract (Q3A-SPEC-005 through Q3A-SPEC-007).
4. Correct cross-references and add FR-to-evidence traceability (Q3A-SPEC-008 and Q3A-SPEC-009).
5. Clarify Phase 0 pass/fail demonstrations and vacuity guarantees (Q3A-SPEC-010 and Q3A-SPEC-011).

## Review Limitations

This report checks the written specification for consistency and readiness. It does not establish conformance to IEEE 1800, prove an implementation sound, select owner-pending decisions, or provide measured performance evidence. The source specification remains unchanged.

