# Specification Refinement Proposal — Q3AFormal Revision 0.9

**Status:** Owner-approved; incorporated into Q3AFORMAL_SPECIFICATION.md revision 0.9  
**Base:** Q3AFORMAL_SPECIFICATION.md revision 0.8  
**Input snapshot:** inputs/Q3AFORMAL_SPECIFICATION_v0.8.md  
**Review findings:** Q3A-SPEC-001 through Q3A-SPEC-011  
**Governance:** This proposal does not edit or replace the canonical specification.

## Recommendation

The owner reviewed and approved the closures below on 2026-11-15, including the balanced Phase 0 RTL/SVA subset. The adopted changes are incorporated in revision 0.9; revision 0.8 remains preserved as an input snapshot. This file records the review rationale and is not the canonical specification.

## Finding-by-Finding Proposed Changes

### Q3A-SPEC-001 — Synchronous reset modeled as initial constraint

**Disposition:** Replace the current initial-constraint-only reset model.

**Proposed clause:**

> State S[t] is the state immediately before active clock edge t. Inputs, including reset, are sampled at that edge. The transition relation computes S[t+1]. Synchronous reset is evaluated on every active edge and is part of T(S[t], I[t], S[t+1]). If reset is asserted at edge t, each register with a synchronous reset assignment takes that reset value in S[t+1]. Reset may remain asserted or be reasserted later. Unless a supported initialization construct or explicit initial assumption constrains it, every state bit is unconstrained in S[0]. A synchronous reset does not constrain S[0] before its first active edge. Startup reset behavior must be an explicit environment assumption.

Required vectors: reset held for multiple edges, release, reassertion, missing reset, resettable and non-resettable state, contradictory startup assumptions, and assertion sampling around the reset edge.

### Q3A-SPEC-002 — Conflicting literal categories

**Disposition:** Replace the current single rule for all unsized literals.

**Proposed rule set:**

- Unsized decimal integer literals use the standard minimum-width, signedness, and expression-context rules.
- Sized based literals use the declared size and optional signed marker under the IEEE 1800 rules.
- Unbased unsized fill literals '0 and '1 fill the receiving context. The two-valued profile rejects 'x and 'z.
- Unsized based literals are excluded from the initial Phase 0 subset until their exact width/signedness behavior is represented by reviewed conformance vectors.
- Every supported category has separate width, signedness, extension, truncation, and context tests. Unsupported cases are diagnosed, not guessed.

### Q3A-SPEC-003 — Open-ended RTL support claims

**Disposition:** Make the versioned conformance matrix normative and limit the Phase 0 subset.

**Proposed clause:**

> A construct is supported only when its exact syntax, elaboration, lowering, semantic rule, diagnostics, and positive/negative evidence are recorded in the versioned conformance matrix. Incomplete or ambiguous rows are unsupported. The initial subset is limited to a single-clock module hierarchy, resolved parameters, packed integral values, continuous assignment, listed combinational and edge-triggered processes, conditionals, and static generate forms whose rows are complete. Generic always, latch inference, interfaces/modports, unions, delays, dynamic constructs, and unlisted forms are rejected until separately specified and reviewed.

The matrix must include one row per supported construct and operation, rather than broad labels such as “selected interfaces” or “always where synthesizable.”

### Q3A-SPEC-004 — Sampling, disable iff, and first-sample ambiguity

**Disposition:** Define one sampling convention and reject unsupported temporal behavior.

**Proposed Phase 0 clause:**

> Concurrent properties sample operands at the preponed sampling point for one explicitly bound positive-edge clock. Under the cycle model, sampled values correspond to S[t] and I[t]; sequential RTL updates form S[t+1]. The initial Phase 0 subset excludes disable iff until its asynchronous abort timing is modeled. It also excludes $past, $stable, $rose, $fell, and $changed until history initialization and two-valued treatment are specified and evidenced. No uninitialized prior sample is assigned a convenient Boolean value.

Support overlapped/non-overlapped implication or repetition only after exact cycle alignment is documented with boundary vectors.

### Q3A-SPEC-005 — Source-to-model validation is not operational

**Disposition:** Add a concrete, independently reviewed evidence corpus.

**Proposed acceptance artifact:** For each supported source construct, record the input source, expected elaborated representation, expected T-IR/transition behavior, source-map expectations, positive and negative cases, and bounded evaluation from an independently structured reference evaluator. Include reset and malformed cases. List metamorphic transformations and the invariant each must preserve. Review expected outputs independently of the implementation. External formal tools are not acceptance oracles.

### Q3A-SPEC-006 — Result bundle omits the exact model

**Disposition:** Include the exact canonical model and distinguish historical inspection from current revalidation.

**Proposed bundle additions:** canonical T-IR, model schema, provenance, model hash, property/query identity, assumptions, proof or witness artifact, and checker report. Source snapshots may remain optional only if source and model identities are recorded. A bundle can display a historic result and replay an included witness, but a PROVEN result is currently revalidated only by a compatible Q3A checker. Without one, label the result historic/unverified by the current executable.

### Q3A-SPEC-007 — Cache key omits implementation identity

**Disposition:** Bind reuse to exact producer and model identities.

**Proposed cache key inputs:** source/configuration, Q3A release/build ID, relevant component and checker fingerprints, profile and schema versions, canonical lowered-model hash, property and assumptions, exact query/CNF identity, proof artifact, and imported trace. A cache hit is not proof evidence; a compatible current checker revalidates conclusive evidence. Semantic or checker changes invalidate entries unless an explicit compatibility rule applies.

### Q3A-SPEC-008 — Stale section references

**Disposition:** Correct subsection numbering: language profiles use §15.1–§15.3; roadmap phases use §16.1–§16.4. Replace nonexistent §17.6 with §17, criterion 6 (assumption and vacuity diagnostics). Replace list-number references such as §18.2 and §18.8 with stable owner-decision identifiers OD-02 and OD-08. Validate every section reference after edits.

### Q3A-SPEC-009 — Missing FR-to-evidence traceability

**Disposition:** Add a traceability table mapping every Q3AF-FR ID to implementation phase, acceptance criterion, and evidence artifact. Mark deferred requirements with their planned release phase. A Phase 0 plan must not imply that requirements assigned to later phases are already satisfied.

### Q3A-SPEC-010 — Ambiguous Phase 0 proof and witness requirement

**Disposition:** Require separate runs.

**Proposed exit criterion:**

> At least one known-pass property must return PROVEN with checker-accepted induction or invariant evidence; finite bounded model checking alone yields only BOUNDED_PASS. A separate known-fail property must return FAIL with a witness validated frame by frame against the exact T-IR and assumptions. One run cannot satisfy both outcomes.

### Q3A-SPEC-011 — Vacuity guarantee is unclear

**Disposition:** Separate vacuity metadata from proof status and state the completeness boundary.

**Proposed rule:**

- Detect contradictory initial constraints and frame-local contradictory assumptions when the corresponding complete query establishes them.
- Record vacuity metadata as DETECTED, NOT_DETECTED_WITHIN_SCOPE, or INCOMPLETE, together with the queried depth or complete procedure.
- A bounded search that does not encounter a property activation is only an incomplete warning; it cannot establish complete unreachability.
- Report assumption inconsistency distinctly so a vacuous proof is not described as functional coverage.

## Cross-Document Corrections Integrated into Revision 0.9

- Updated the change-history summary and review-disposition table.
- Corrected section headings and internal references.
- Updated FR-012 and FR-036 to match the vacuity and cache contracts.
- Added requirements for source-to-model evidence, exact-model bundles, build/checker cache identity, reset transitions, traceability, and vacuity completeness.
- Added stable acceptance IDs and mapped the full functional-requirement set to phases and evidence.
- Recorded owner-approved decisions in revision 0.9; remaining proof-format and benchmark choices are explicitly deferred to their evidence gates.

## Owner Review Gate

Gate A was approved on 2026-11-15. Remaining Gate B/evidence decisions are:

1. Whether to retain C++17 for the product MVP after portability evidence.
2. Final proof-artifact/checker format after prototype evidence.
3. Numeric benchmark thresholds before measurement and exact host/compiler configuration.
4. Any requested extension of the approved balanced RTL/SVA subset.
5. Gate B GO or NO-GO after evidence review.
## Terminology

| Abbreviation | Meaning |
|---|---|
| CNF | Conjunctive normal form |
| FR | Functional requirement |
| IEEE | Institute of Electrical and Electronics Engineers |
| IR | Intermediate representation |
| RTL | Register-transfer level |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |


### Proposed FR-to-phase-to-evidence matrix

Use the existing numbered acceptance criteria in §17 for the current requirements. Add criteria for any requirement that has no matching measurable acceptance outcome.

| Functional requirement IDs | Phase | Acceptance evidence |
|---|---|---|
| Q3AF-FR-001–006, 039, 040, 044 | Phase 0 profile subset; Phase 1 product support | §17 criteria 1–2; source-to-model conformance corpus |
| Q3AF-FR-007–009, 012–013, 038 | Phase 0 proof/checker subset; Phase 1 engine | §17 criteria 3, 5–6, 16; proof and checker reports |
| Q3AF-FR-010, 014, 016, 027, 030–031 | Phase 0 witness path; Phase 1 product support | §17 criteria 4, 7; replay report and result bundle |
| Q3AF-FR-011, 035–036, 041–042 | Phase 0 evidence format; Phase 1 product support | §17 criteria 8; manifest, model hashes, cache revalidation record |
| Q3AF-FR-015, 019–024, 029 | Phase 1 | Add measurable CLI/debug criteria; machine-readable status and GUI acceptance record |
| Q3AF-FR-017–018, 037 | Phase 1 | §17 criteria 11–12, 17; trace round-trip and navigation evidence |
| Q3AF-FR-025–026 | Phase 0 architecture decision; all releases | Dependency/provenance inventory and release manifest |
| Q3AF-FR-028, 032–034 | Phase 1; scalability additions in Phase 2 | §17 criteria 9–10, 15; module and resource reports |
| Q3AF-FR-043 | Phase 0 governance artifact | Reviewed traceability matrix |
| Q3AF-FR-045 | Phase 0 limited diagnostics; Phase 1 supported scope | §17 criterion 6; vacuity metadata and completeness record |

Phase 0 evidence does not close requirements assigned to Phase 1 or Phase 2. Add or extend acceptance criteria before implementation wherever the table says “Add measurable criteria.”




