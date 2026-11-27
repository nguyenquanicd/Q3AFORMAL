# Q3AFormal Specification Review

**Reviewed document:** Q3AFORMAL_SPECIFICATION.md
**Reviewed revision:** 0.8
**Review date:** 2026-11-15
**Review scope:** Technical consistency, formal-method soundness boundaries, product scope, implementation feasibility, and testability.
**Change control:** This is a separate review report. The reviewed specification was not modified.

> This revision re-verifies the findings originally raised against revision 0.7 and records their disposition in revision 0.8. The original findings (R-01 through R-10) are preserved below with a per-finding resolution annotation.

## 1. Executive Assessment

Revision 0.8 resolves the principal blockers identified in revision 0.7. It defines concrete RTL/SVA semantic rules (§15), enumerates five proof-evidence obligations with an explicit trusted-versus-checked boundary (§10.3), fixes the M8 witness-validation contract (§6.2, §9), and specifies a default reset and initial-state policy (§7.2). It additionally adds assumption temporal semantics (§5.3), VCD interchange behavior (§12.3), Phase 0 exit gates (§16.1), a CANCELLED status and cache-key policy (§5, §11.3), public interface definitions (§13), checker validation (§10.4), and property-binding rules (§6.4).

The document is now a **sound basis for Phase 0 planning**. The items that remain open are, correctly, owner decisions rather than specification gaps: the reset/initialization policy (§7.2), the operating-system and baseline-hardware profile, the proof-artifact format (to be selected after the Phase 0 prototype), and the C++17 implementation language. These are gated by the Phase 0 exit criteria (§16.1) and are expected to remain provisional until a feasibility prototype produces evidence.

The specification still is not a claim of measured performance or of conformance: no benchmark or conformance evidence is asserted to have been run, and acceptance thresholds are deferred to the Phase 0 go/no-go gate. This is appropriate for a pre-implementation specification.

## 2. Finding Disposition in Revision 0.8

| Finding | Severity (0.7) | Disposition in 0.8 | Resolved at |
|---|---|---|---|
| R-01 Freeze the RTL/SVA semantic profile | Critical | Resolved — concrete semantics now written for sizing/signedness, unsized literals, casts, shifts, indexing, generate, sampling, first-sample, disable, and sampled-value functions. Final matrix freeze remains a Phase 0 gate. | §15.1–15.3 |
| R-02 Complete the source-to-proof trust chain | Critical | Resolved — five evidence obligations with trusted/checked boundary and explicit TCB. | §10.3 |
| R-03 Resolve the M8 witness-validation contract | High | Resolved — M11 emits a candidate witness; M8 validates it before display. | §6.2, §9 |
| R-04 Specify reset and initial-state semantics | Critical | Resolved — default synchronous-reset, initial-constraint model with uninitialized = unconstrained. Pending owner approval. | §7.2 |
| R-05 Define assumptions as part of every proof obligation | High | Resolved — per-frame placement and per-engine application. | §5.3 |
| R-06 Clarify VCD import and four-state handling | High | Resolved — two import use cases; X/Z reject or display-only, never silent coercion. | §12.3 |
| R-07 Set the Phase 0 feasibility gate | High | Resolved — six explicit exit criteria and go/no-go owner review. | §16.1 |
| R-08 Make reproducibility and cancellation status complete | Medium | Resolved — CANCELLED status and full cache-key policy. | §5, §11.3, FR-035/036 |
| R-09 Add operational definitions for the public interface | Medium | Resolved — manifest schema, CLI grammar, bundle layout, versioning. | §13 |
| R-10 Distinguish product constraints from implementation alternatives | Medium | Resolved — dependency boundary frozen; C++17 provisional pending Phase 0. | §8 |
| Gap 1 Who validates the proof checker | Medium | Resolved — checker validation corpus (valid/invalid/malformed). | §10.4 |
| Gap 2 Assertion/property attachment and binding | Medium | Resolved — inline/bound/top-level with name-resolution precedence. | §6.4 |
| Gap 3 RESOURCE_LIMIT already present | — | Acknowledged; remaining taxonomy gap closed by R-08. | — |

## 3. Strengths to Preserve

1. **Clear result taxonomy.** BOUNDED_PASS is not conflated with PROVEN, and UNREACHABLE requires complete reachability evidence (§5). CANCELLED is now distinct from UNKNOWN, TIMEOUT, and ENGINE_ERROR.
2. **Explicit model boundary.** Results are stated to apply to the elaborated transition-system model and assumptions; source-to-model correctness is recognized as a separate obligation (§5, §10.3).
3. **Realistic resource language.** Parallelism is optional, speedup is measured rather than guaranteed, and resource exhaustion must produce a non-conclusive result (§11).
4. **Scoped debug execution.** M8 replays and reconstructs formal witnesses instead of attempting a general testbench simulator (§9).
5. **Reviewable no-third-party policy.** Runtime dependencies, build tools, source provenance, and reference-only projects are distinguished and frozen (§8).
6. **Useful trace and GUI direction.** Lazy trace access, viewport rendering, property-to-waveform-to-source navigation, and session persistence are specified (§12–13).
7. **Implementation realism.** C++17, proof-artifact format, baseline hardware, and several semantic decisions are marked provisional or open rather than presented as measured outcomes (§18).

## 4. Findings (original text with 0.8 disposition)

### R-01 — Freeze the RTL and SVA semantic profile before implementation

**Severity:** Critical
**Pointers (0.7):** §§4.3, 7, 14, 15; Q3AF-FR-004 and Q3AF-FR-005

The specification identifies IEEE 1800-2023 as its language baseline, but the MVP profile remains a list of candidate constructs. It does not yet define exact semantics for expression sizing and signedness, unsized literals, casts, shift behavior, array indexing, generate resolution, concurrent assertion sampling, first-sample behavior, disable conditions, or the selected sampled-value functions.

**Why it matters:** A parser can accept a construct while the elaborator or lowering assigns it different semantics. A proof can then be internally valid for the wrong model.

**Resolution in 0.8:** §15.1–15.3 now specifies these semantics in detail and requires a conformance matrix in which a construct is "supported" only when parse, elaborate, lower, and semantic-test columns are all complete. The exact conformance matrix remains a Phase 0 deliverable (§16.1), which is the correct place for it.

### R-02 — Complete the source-to-proof trust chain

**Severity:** Critical
**Pointers (0.7):** §§5, 6.2, 10.1, 10.3; M9–M11

The specification correctly says that a checker operating on T-IR does not certify source-to-model translation. However, it does not define how the implementation will validate the transformations from RTL/SVA through T-IR and then from T-IR to the SAT formula.

**Why it matters:** The product's central promise is a sound proof result. Every transformation and proof obligation must be attached to the correct checker or trusted component.

**Resolution in 0.8:** §10.3 defines five evidence obligations (witness replay, SAT model, CNF unsatisfiability, k-induction base/step, PDR invariant) with a table recording, for each, what is checked versus trusted, and enumerates the trusted computing base.

### R-03 — Resolve the M8 witness-validation contract

**Severity:** High
**Pointers (0.7):** §6.2, M8 row; §§6.1 and 9.2

M8's input contract requires "validated witness frames," while M8 is also responsible for replaying and checking every witness frame before the trace is presented as a validated counterexample.

**Why it matters:** The interface contract is circular or incomplete.

**Resolution in 0.8:** M11 now emits an *unvalidated candidate witness*; M8 (with the trace checker) validates every frame against T-IR and the recorded assumptions before the witness may be displayed or reported as FAIL. The circular input is removed.

### R-04 — Specify reset and initial-state semantics

**Severity:** Critical
**Pointers (0.7):** §§5, 7, 14.1; owner decisions 1–2 in §17

The model defines S₀ as the permitted initial states "after applying" reset and initialization policy, without fixing the policy.

**Why it matters:** Changing S₀ changes the reachable-state set and can change PROVEN, FAIL, and COVERED outcomes.

**Resolution in 0.8:** §7.2 defines a concrete default: single synchronous reset as an initial-state constraint, active-high by default, registers without reset modeled as unconstrained (both 0 and 1) rather than a convenient constant, and a required acceptance corpus including reset-held, reset-released, missing-reset, and contradictory-assumption cases. This remains a proposed default pending owner approval (§18.2).

### R-05 — Define assumptions as part of every proof obligation

**Severity:** High
**Pointers (0.7):** §§5, 10.2, 10.3, 11.1

Assumptions are recorded and reported, but their exact temporal placement in BMC, k-induction, PDR, and invariant checking is not specified.

**Why it matters:** Omitting, shifting, or inconsistently applying assumptions can produce unsound results.

**Resolution in 0.8:** §5.3 defines assumption scope (each transition frame, optional initial constraint), per-engine application (BMC conjoins at each frame; k-induction in base and step; PDR folds the assumption into the frame relation), contradictory-assumption handling, and the requirement that the checker validate evidence under the same assumption semantics.

### R-06 — Clarify VCD import and four-state data handling

**Severity:** High
**Pointers (0.7):** §§7, 12.1; Q3AF-FR-018 and Q3AF-FR-028

The MVP model is two-valued, while the required VCD interchange format can carry values beyond 0 and 1.

**Why it matters:** Import may be mistaken for formal evidence, or a four-state waveform may be silently coerced into the two-valued model.

**Resolution in 0.8:** §12.3 defines two import use cases (Q3A round-trip and external viewing), an X/Z policy (never silent coercion; external traces marked non-formal), duplicate-identifier/alias handling, and timestamp/timescale round-trip requirements. FST remains optional.

### R-07 — Set the Phase 0 feasibility gate and benchmark protocol

**Severity:** High
**Pointers (0.7):** §§3.2, 15–17

The roadmap asks Phase 0 to prototype the full stack but has no explicit exit criteria.

**Why it matters:** The project could progress into a very large implementation without an objective decision point.

**Resolution in 0.8:** §16.1 defines six explicit exit criteria: frozen benchmark set, one assertion demonstrated end-to-end, proof checker passing the valid/invalid corpus, measured peak memory/runtime on a named hardware profile, C++17 feasibility validated, and a recorded go/no-go owner decision.

### R-08 — Make reproducibility and cancellation status complete

**Severity:** Medium
**Pointers (0.7):** §§5, 6.3, 11.2; Q3AF-FR-008, Q3AF-FR-011, Q3AF-FR-014

The Proof Manager supports cancellation, but the result taxonomy has no CANCELLED status, and cache keys are incomplete.

**Why it matters:** A cancelled run may be confused with UNKNOWN or ENGINE_ERROR, and cached artifacts may not be tied to the exact semantics that produced them.

**Resolution in 0.8:** §5 adds a CANCELLED status; §11.3 defines cache keys covering the semantic-profile version, IR schema versions, proof query, generated CNF, and imported trace; FR-035 and FR-036 codify these.

### R-09 — Add operational definitions for the public interface

**Severity:** Medium
**Pointers (0.7):** §§6, 12–13

The specification does not specify the manifest schema, command grammar, output bundle layout, or compatibility policy.

**Why it matters:** Different implementations could produce incompatible projects, reports, or debug bundles.

**Resolution in 0.8:** §13 specifies the project manifest schema, CLI grammar and exit codes, result-bundle layout, and a versioning/migration policy covering schemas, sessions, and traces.

### R-10 — Distinguish product constraints from implementation alternatives

**Severity:** Medium
**Pointers (0.7):** §§8–9, 17

The no-third-party rule leaves compiler/build tools and OS GUI APIs as owner decisions; native-code and event-driven execution are deferred; C++17 is provisional.

**Why it matters:** Implementation alternatives may accidentally introduce runtime frameworks that violate the dependency rule.

**Resolution in 0.8:** §8 freezes the dependency boundary (no third-party GUI framework; generic compiler/linker and OS APIs permitted; C++17 provisional until Phase 0). §9.1 keeps the MVP on the interpreted replay path, with bytecode and native/event-driven execution gated behind measurement and review.

## 5. Remaining Owner Decisions (not specification gaps)

These are correctly deferred to owner approval and are gated by the Phase 0 exit criteria (§16.1):

1. Approve the precise RTL and SVA conformance profiles (§15).
2. Approve the two-valued initialization and reset policy (§7.2).
3. Select the first operating system and baseline hardware profile.
4. Approve the native trace schema and decide whether FST is required.
5. Approve the proof artifact and checker format after the Phase 0 prototype.
6. Confirm the frozen third-party dependency boundary (§8).
7. Approve measurable runtime, memory, design-size, and trace-navigation targets from benchmark results.
8. Confirm whether C++17 remains the implementation language after the feasibility review.

## 6. Review Conclusion

Revision 0.8 resolves all findings raised against revision 0.7 and is suitable as a **basis for Phase 0 planning**. The remaining open items are owner decisions and Phase 0 deliverables, not specification gaps. The highest-priority next step is to execute Phase 0 and produce the conformance and feasibility evidence that the specification's acceptance criteria require. No benchmark results or implementation evidence are claimed by this review or by the reviewed specification.

## 7. External Technical References

- [IEEE 1800-2023 standard scope](https://standards.ieee.org/ieee/1800/7743/)
- [Bradley, SAT-Based Model Checking Without Unrolling](https://theory.stanford.edu/~arbrad/papers/IC3.pdf)
- [DRAT format and DRAT-trim checker](https://arxiv.org/abs/1610.06229)
- [k-Induction base and step overview](https://kind.cs.uiowa.edu/kind2_user_doc/1_techniques/2_kinduction.html)
