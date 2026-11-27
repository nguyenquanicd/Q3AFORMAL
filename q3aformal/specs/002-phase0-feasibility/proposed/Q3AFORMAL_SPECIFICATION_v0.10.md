# Q3AFormal — Technical Specification

**Status:** Draft for technical review; Phase 0 RTL/SVA subset selected by owner
**Version:** 0.10
**Date:** 2026-11-15
**Purpose:** Define the product scope, architecture, proof semantics, model semantics, language profiles, public interfaces, implementation phases, and acceptance criteria for an independent formal-verification tool for application-specific integrated circuit (ASIC) designs written at the register-transfer level (RTL).

> Revision 0.10 retains the owner-approved dispositions of Q3A-SPEC-001 through Q3A-SPEC-011 and records a follow-up Phase 0 decision: connected module ports must have exact bit-width matches. The owner selected the balanced RTL/SVA subset, positive repetition bounds, exact-width ports, C++17, and Windows x64 on 2026-11-15. Revision 0.9 is preserved as a snapshot; final MVP language, proof format, and numeric benchmark thresholds remain subject to later review.
>
> "Q3AFormal" is the product name. The owner has not supplied an expansion for "Q3A."

## 1. Executive Summary

Q3AFormal is a proposed formal-verification application for synthesizable RTL and SystemVerilog Assertions (SVA). It will translate a supported RTL and SVA profile into a finite-state model, check properties under explicit environment assumptions, return validated counterexamples, and prove supported safety properties when a complete proof procedure converges.

The intended product is self-contained at runtime. Q3AFormal must implement its own frontend, elaborator, transition-system lowering, Boolean satisfiability (SAT) solver, model-checking algorithms, trace storage, waveform handling, and graphical user interface (GUI). It must not invoke or link third-party electronic design automation (EDA) or formal-verification engines, solvers, simulators, waveform viewers, or converters. External projects listed here are research references only.

The long-term language target is **complete conformance to a published, RTL-focused formal profile**, not an unrestricted implementation of every feature in the Institute of Electrical and Electronics Engineers (IEEE) 1800 SystemVerilog standard. The profile must name supported constructs and semantics. Q3AFormal must reject unsupported constructs rather than ignore or silently simplify them.

The minimum viable product (MVP) is limited to a single-clock, synchronous, two-valued formal model; a published synthesizable RTL subset; and a published concurrent SVA subset. Its debug execution component replays formal witnesses and reconstructs selected signal values. It is not a general-purpose testbench simulator.

## 2. Review Findings and Disposition

This revision incorporates the approved recommendations from the independent specification review.

| Finding | Severity | Disposition in revision 0.10 |
|---|---|---|
| Q3A-SPEC-001: synchronous reset model | Critical | §7.2 models synchronous reset in every transition and defines initial-state and sampling conventions. |
| Q3A-SPEC-002: literal categories | High | §15.1.1 separates numeric literals from unbased unsized fill literals and rejects unsupported categories. |
| Q3A-SPEC-003: open-ended RTL subset | High | §15.1 makes the owner-selected balanced subset and rejection boundary explicit. |
| Q3A-SPEC-004: SVA sampling, disable, history | High | §15.2 defines the selected SVA subset, bounded repetition, guarded $past, and explicit exclusions. |
| Q3A-SPEC-005: source-to-model evidence | High | §10.3 and §16.1 require an independently reviewed source-to-model corpus and reference evaluation. |
| Q3A-SPEC-006: result bundle identity | High | §13.3 stores the exact lowered model and evidence and distinguishes historical status from current revalidation. |
| Q3A-SPEC-007: cache identity | High | §11.3 binds cache entries to build/component/checker fingerprints and exact model/query/evidence hashes. |
| Q3A-SPEC-008: stale section references | Medium | Subsection numbering and references are corrected; owner decisions use stable IDs. |
| Q3A-SPEC-009: requirement traceability | Medium | §17.2 maps every functional requirement to a phase and acceptance evidence. |
| Q3A-SPEC-010: Phase 0 pass/fail ambiguity | Medium | §16.1 requires separate known-pass and known-fail runs; finite bounded checking cannot produce PROVEN. |
| Q3A-SPEC-011: vacuity scope | Medium | §5.3 defines contradiction checks and completeness labels for vacuity analysis. |

## 3. Product Goals and Design Principles

### 3.1 Product goals

1. Accept a project manifest that identifies source files, include paths, macros, parameter overrides, and a top-level design unit.
2. Elaborate supported RTL deterministically and report source-located diagnostics.
3. Parse and check assertions, assumptions, and cover properties in the published SVA profile.
4. Lower the design and properties into a precisely defined transition-system representation with source provenance.
5. Provide bounded model checking (BMC), cover search, k-induction, and property-directed reachability (PDR) for supported safety properties.
6. Return a validated witness for a failing property and a checkable proof artifact for a completed proof.
7. Replay a witness, reconstruct selected internal values, and create a navigable trace without rerunning the proof.
8. Provide an integrated, minimal debug workflow from property result to waveform to source.
9. Ship as a self-contained application without third-party formal or simulation engines at runtime.

### 3.2 Design principles

1. **Soundness before speed.** A fast but unsound result is a defect. Unsupported semantics must fail explicitly.
2. **Explicit model semantics.** Clock, reset, initial-state, memory, and unknown-value policies are part of the run configuration.
3. **Measured resource adaptation.** Scheduling may adapt to available resources, but may not weaken a proof obligation silently.
4. **Internal modularity.** Modules use versioned typed interfaces and are tested independently; implementation boundaries do not imply separate executables.
5. **Traceability.** Source locations and transformation provenance must be retained through elaboration and lowering.
6. **Conservative status reporting.** Resource exhaustion, timeout, unsupported semantics, cancellation, and incomplete bounds must never be reported as proof.
7. **Reproducibility with declared limits.** Inputs, tool build, options, seeds, resource limits, and model semantics are recorded. Exact runtime and the first witness found may differ across machines or parallel schedules.

### 3.3 Research-derived capability map

The projects below inform requirements only. None is a Q3A runtime or build dependency, and no implementation code is to be copied or linked.

| Reference project | Capability to study | Q3A-owned implementation |
|---|---|---|
| Yosys | Deterministic elaboration passes, hierarchy handling, and IR design | Source Manager, frontend, typed IR, deterministic transformations |
| SymbiYosys (SBY) | Job orchestration, proof/cover tasks, status reporting, reproducible run manifests | Proof Manager, task model, status taxonomy, logs, saved run configuration |
| ABC (project name) | SAT-based search and PDR techniques | Q3A CDCL solver and Q3A PDR implementation |
| Bitwuzla, Z3 (project name), Boolector, cvc5 (project name) | SMT support for bit-vectors and arrays | MVP bit-blasting to SAT; later Q3A-owned word-level reasoning |
| Pono model checker (project name) | Transition-system interfaces and algorithm portfolio | Q3A model-checking API and separately validated algorithms |
| EQY, the Yosys equivalence-checking project | Signal matching, partitioning, equivalence proof decomposition | Q3A-native equivalence checking after proof-composition rules |
| slang | SystemVerilog parsing, elaboration, source diagnostics | Q3A-owned lexer, parser, elaborator, diagnostics |
| GTKWave and Surfer | Hierarchy navigation, signal search, groups, cursors, markers, radix, zoom, trace interaction | Q3A-owned trace store, codecs, renderer, debug interface |
| Verilator | Compiled simulation architecture and signal evaluation | Q3A witness replay only; general simulator out of MVP scope |

## 4. Scope and Product Boundaries

### 4.1 In scope

- Block-level and subsystem-level ASIC RTL.
- A versioned synthesizable SystemVerilog profile (detailed in §15). Verilog-2005 compatibility may be included where it is part of that profile.
- Concurrent SVA constructs explicitly listed in the supported profile.
- Single-clock synchronous designs in the MVP.
- Control and protocol logic: FIFOs, arbiters, counters, FSMs, interrupts, CSRs, bus channels, and protocol adapters.
- Formal witness generation, replay, selected-signal reconstruction, trace export, and source navigation.

### 4.2 Out of scope for the MVP

- UVM testbenches, classes, constrained-random testbenches, and DPI calls.
- Analog or mixed-signal verification.
- Gate-level timing simulation using Standard Delay Format (SDF) or delay back-annotation.
- General-purpose simulation of user-authored testbenches or arbitrary stimulus.
- A claim of feature parity with commercial sign-off tools.
- Multi-clock and general event-region scheduling.
- Automatic proof of design intent when no suitable properties or reference model are supplied.
- Four-valued (X/Z) semantics. The MVP is two-valued; a four-valued profile is a separate future review (§7.1).

### 4.3 Language conformance target

The language baseline is IEEE 1800-2023. Q3AFormal must publish a conformance matrix for its supported RTL and SVA profile. A construct is supported only when parsing, elaboration, lowering, and semantic acceptance criteria are all implemented. The product must not claim unrestricted "full SystemVerilog" or "full SVA" support while any required construct in the declared profile is missing.

## 5. Proof Semantics, Assumptions, and Result Status

### 5.1 Model boundary

Q3AFormal proves properties of the **elaborated transition-system model and its recorded assumptions**. A proof result does not, by itself, prove that the frontend and lowering implementation correctly captured every source-language semantic rule. Those components require their own conformance evidence (§10.3).

For the MVP, the model is a finite-state, single-clock synchronous system:

**M = (S, I, T, S₀)**

where **S** is the state, **I** is the environment input, **T(S, I, S′)** is the transition relation, and **S₀** is the set of permitted initial states after applying the declared reset and initialization policy (§7.2). Inputs are unconstrained unless restricted by explicit assumptions (§5.3).

### 5.2 Result status

| Status | Meaning |
|---|---|
| **PROVEN** | A complete proof procedure produced an invariant or other accepted proof artifact, and the Q3A checker validated it against the lowered model. |
| **FAIL** | A satisfying witness to a property violation was replayed and validated against the lowered model. |
| **BOUNDED_PASS** | No violation was found within the reported finite BMC depth. This is not an unbounded proof. |
| **COVERED** | A witness reaching the cover goal was found and validated. |
| **UNREACHABLE** | A complete reachability procedure proved the cover goal unreachable in the recorded model. A bounded miss is insufficient. |
| **UNKNOWN** | The procedure stopped without a sound proof or counterexample. |
| **TIMEOUT** | The configured time limit expired without a conclusive result. |
| **RESOURCE_LIMIT** | A declared memory, solver, or execution budget was reached without a conclusive result. |
| **CANCELLED** | The run was cancelled by an explicit operator or policy action before reaching a conclusive result. |
| **UNSUPPORTED** | The input uses a construct or semantic mode not implemented in the selected profile. |
| **ELABORATION_ERROR** | The project could not be elaborated under the supplied configuration. |
| **ENGINE_ERROR** | An internal execution or consistency failure prevented a valid result. |

`CANCELLED` is distinct from `UNKNOWN`, `TIMEOUT`, and `ENGINE_ERROR`: it records an intentional interruption, and the run bundle must record the cancellation cause and the work completed up to that point.

Additional rules:

- An unsatisfiable BMC query through depth *k* produces **BOUNDED_PASS**, not **PROVEN**.
- A k-induction proof requires successful base checks over the required initial prefix and a valid inductive-step check under the recorded assumptions. A failed induction step is inconclusive; it is not necessarily a reachable counterexample.
- A PDR proof is accepted only when the final inductive invariant includes the initial states, is preserved by the transition relation under the assumptions, and implies the safety property.
- A **FAIL** result requires a model witness and a replay check. A **PROVEN** result requires a proof-artifact check.
- The proof checker validates evidence against Q3A's lowered model. It does not replace frontend conformance testing or independently certify source-to-model translation.
- Contradictory assumptions, reset assumptions, black boxes, cutpoints, memory abstractions, and vacuity-analysis scope must be reported. Complete claims of unreachable property activation require complete reachability evidence; bounded misses are labeled incomplete.
- Every parameter and generate configuration is a distinct proof target unless a separately justified symbolic-parameter method is implemented.

### 5.3 Assumption semantics

Assumptions (`assume property`) restrict the legal environment. Their temporal placement must be identical across every engine and the checker.

- **Scope.** An assumption is a predicate over `(S, I)` at a sampled point. It constrains the environment input `I` at **each transition frame**; if the assumption references state, it additionally constrains the state at that frame.
- **Initial-state application.** By default an assumption applies to every transition frame `t ≥ 0`, including the first. An assumption that must hold only at the initial state is expressed as an initial-state constraint and recorded as such.
- **BMC.** At each unrolled frame `0..k`, the assumption predicate is conjoined with the unrolled transition constraint.
- **k-induction.** The base cases conjoin the assumption at every base frame; the step case conjoins the assumption at each of the `k+1` frames involved in the step obligation.
- **PDR/IC3.** The assumption is folded into the frame relation as a constraint on inputs and state; the inductive invariant's consecution obligation is `Fᵢ ∧ A ∧ T → Fᵢ₊₁′`.
- **Guaranteed contradiction checks.** Detect an unsatisfiable initial-state constraint set and frame-local contradictory assumptions when the corresponding SAT query is complete. Record checked scope and evidence. If no legal initial state exists, do not present downstream property results as functional coverage.
- **Recorded identity.** The exact assumption set, its encoding, and placement are part of the run manifest and proof artifact. The checker validates evidence under the same semantics. Vacuity is separate metadata, not a substitute proof status: report DETECTED, NOT_DETECTED_WITHIN_SCOPE, or INCOMPLETE. A bounded search with no property activation is only an incomplete warning; it cannot establish complete unreachability. Record the depth or completeness procedure.

## 6. Architecture

### 6.1 Data and control flow

1. M1 Source Manager reads the project manifest and source tree.
2. M2 Preprocessor, M3 Lexer, M4 Parser, and M5 Elaborator create a deterministic typed design model.
3. M6 SVA Compiler parses supported properties and binds them to elaborated symbols (§6.4).
4. M7 RTL/SVA Lowering creates the transition-system model and provenance.
5. M12 Proof Manager schedules the query and enforces resource budgets.
6. M9 Bit-blaster and M10 SAT Solver provide queries to M11 Model Checker.
7. M11 returns a status and, where applicable, an **unvalidated candidate witness** or a proof artifact.
8. M8 Witness Replay validates the candidate witness against T-IR and reconstructs selected values.
9. M13 Trace Store writes validated trace artifacts consumed by M14 Debug GUI.

The proof manager schedules jobs and enforces budgets; it does not change model semantics. Witness replay consumes a **candidate** witness plus the same transition-system representation used by the proof path, and it produces the validated witness consumed downstream.

### 6.2 Internal modules

Each module has a typed input contract, typed output contract, diagnostic contract, versioned schema where applicable, and isolated tests. Diagnostic commands are optional and do not define separate products.

| ID | Module | Input | Output | Responsibility |
|---|---|---|---|---|
| M1 | Source Manager | Project manifest and source tree | Deterministic project configuration and source hashes | File order, include paths, macros, parameters, top unit, provenance |
| M2 | Preprocessor | Source text and macro environment | Preprocessed tokens/text and expansion map | Supported include and conditional-compilation semantics |
| M3 | Lexer | Preprocessed source | Tokens with source spans | Lexical analysis and source-located errors |
| M4 | Parser | Token stream | Abstract syntax tree (AST) | Syntax parsing; no silent token or construct skipping |
| M5 | Elaborator | AST and project configuration | Elaborated hierarchy and typed design representation | Parameters, generate constructs, types, hierarchy, bindings |
| M6 | SVA Compiler | SVA syntax tree and elaborated symbols | Property automata or predicates with semantic metadata | Property syntax, clock/reset binding, sequence lowering |
| M7 | RTL/SVA Lowering | Elaborated design and properties | T-IR and provenance | State/transition construction, property attachment, model-policy tagging |
| M8 | Witness Replay and Signal Reconstruction | T-IR, **candidate witness frames**, signal selection | **Validated** replay values and trace samples | Replay, combinational-value reconstruction, witness validation (§9.2) |
| M9 | Bit-blaster | T-IR and property query | CNF clauses | Exact bit-vector lowering for the supported profile |
| M10 | SAT Solver | CNF query and assumptions | SAT/UNSAT result, model, proof artifact | Q3A-owned CDCL solver |
| M11 | Model Checker | T-IR and solver interface | Status, **candidate witness**, or proof artifact | BMC, k-induction, PDR, cover search |
| M12 | Proof Manager | Jobs, properties, and resource policy | Scheduled runs and composed statuses | Resource limits, cancellation, logging, cache, result aggregation |
| M13 | Trace Store | Validated witness, replay values, provenance | Versioned native trace and interchange files | Sparse storage, indexing, selective reads, trace manifests |
| M14 | Debug GUI | Result bundle, trace, and source map | Interactive debug session | Property navigation, waveform, source cross-probing, session persistence |

**Contract resolution for R-03:** M11 produces a *candidate* witness that is **not** trusted on entry to M8. M8 (together with the trace checker) validates every frame of the candidate against T-IR and the recorded assumptions. Only after validation does the witness become a validated counterexample that may be displayed, exported, or reported as `FAIL`. No upstream module is assumed to have pre-validated the witness.

### 6.3 Interface requirements

1. Every serialized internal representation carries a schema version. A module rejects an incompatible schema instead of guessing.
2. A diagnostic contains a stable code, severity, message, source span when available, and related notes.
3. Every transformed node retains source provenance or an explicit "no direct source mapping" marker.
4. Module tests operate on the published internal contract, not private data structures from another module.
5. The implementation may replace an internal module only when the replacement preserves the published contract and acceptance criteria.
6. Deterministic mode records random seeds and relevant scheduling options. Parallel execution may change runtime and which valid witness is discovered first.

### 6.4 Property attachment and binding

Properties may appear in the following places, with a fixed precedence when a property identifier is ambiguous:

1. **Inline** in the RTL module that owns the design signals (`assert property` inside a module body). Inline properties inherit the enclosing module's scope and clocking context.
2. **Bound module** via a `bind` directive that injects a property module into an instance or module. The bind target, instance path, and the bound module must be fully elaborated before property lowering.
3. **Top-level property file** referenced by the manifest, whose properties refer to design signals by hierarchical name.

Name-resolution precedence when an identifier is ambiguous: (1) the innermost lexical scope of the property's own container; (2) the elaborated hierarchy named by an explicit hierarchical path; (3) a diagnostic if the reference remains ambiguous. M6 must record, for every property, the exact elaborated signal set it references and the clock/reset context, so the lowering provenance is unambiguous.

## 7. Intermediate Representations and Model Semantics

### 7.1 IR layers

| Layer | Name | Contents | Producer | Consumer |
|---|---|---|---|---|
| IR-1 | AST | Syntax tree, declared types, source spans | M4 | M5 and M6 |
| IR-2 | Elaborated IR (E-IR) | Resolved hierarchy, parameters, generate instances, nets, registers, memories, types | M5 | M6 and M7 |
| IR-3 | T-IR | State, inputs, transition relation, initial-state constraints, properties, model policy, provenance | M7 | M8, M9, M11 |

The MVP T-IR is a typed expression directed acyclic graph shared by the bit-blaster and the replay evaluator. Sharing reduces duplicate semantic implementations but does not eliminate the need for independent conformance tests.

**Logic model.** The MVP uses two-valued logic (0, 1) for its explicitly supported synthesizable subset. Four-valued logic (0, 1, X, Z) is a separate future semantic profile. The tool must not automatically switch between two-valued and four-valued interpretations within a proof. A construct whose two-valued semantics differ from its four-valued semantics (for example, unknown-value propagation in a mux or case statement) must be handled by an explicit, recorded policy or rejected.

**Uninitialized state.** Uninitialized state (a register without a reset) is represented according to the declared initialization policy (§7.2). It must not be assigned a convenient constant by default, because doing so can silently remove reachable states and make a proof unsound.

### 7.2 Reset and initial-state semantics (proposed MVP default)

The owner-approved default models reset in the transition relation, not as an initial-state substitute.

- **Cycle model.** State S[t] is the state immediately before active clock edge t. Inputs, including reset, are sampled at that edge. The transition relation computes S[t+1].
- **Synchronous reset.** Reset is evaluated at every active clock edge and is included in T(S[t], I[t], S[t+1]). If reset is asserted at edge t, each register with a synchronous reset assignment takes that value in S[t+1]. Reset may remain asserted or be reasserted later.
- **Reset configuration.** The manifest declares reset signal, polarity, and clock edge. The Phase 0 profile uses one positive-edge clock and one synchronous reset. Asynchronous reset is outside the approved Phase 0 subset.
- **Initial states.** Unless a supported RTL initialization construct or explicit initial assumption constrains them, state bits are unconstrained in S[0]. Synchronous reset does not constrain S[0] before its first active edge.
- **Unreset state.** Registers without reset assignments remain unconstrained initially and evolve according to their transition logic.
- **Clock and assertion sampling.** Concurrent properties sample preponed values at the active edge, corresponding to S[t] and I[t]; sequential RTL updates produce S[t+1].
- **Reset assumptions.** Any startup protocol is an explicit environment assumption in the manifest and proof obligation. No startup reset is silently assumed.
- **Acceptance evidence.** Separate cases cover reset held for multiple edges, release, later reassertion, missing reset, and unconstrained initial state. Cases verify both state transition and property sampling.

### 7.3 Memory policy

- Small memories may be represented exactly by state bits and selection logic. Storage cost is proportional to the number of represented bits; read and write logic also depends on memory depth and width.
- A large memory may not be replaced by an unconstrained or abstract object and then used to claim a proof of the concrete design without a sound abstraction relation.
- The MVP may support exact lowering for bounded memories in its language profile and reject other cases. Native array reasoning or abstraction refinement is a later feature requiring its own soundness argument.

## 8. Third-Party Dependency Boundary

- The released application must not execute, link, embed, or require third-party parsers, elaborators, simulators, formal engines, SAT/SMT solvers, waveform viewers, waveform converters, plugins, or cloud services.
- Q3A must own the source for its frontend, model checker, solver, proof checker, witness replay, trace store, file-format codecs, renderer, and debug interface.
- Generic operating-system (OS) services, application programming interfaces (APIs), language standard libraries, and a compiler/linker used to build Q3A are permitted. They must not supply proof semantics or proof results at runtime.
- **No third-party graphical user interface framework or runtime library is permitted.** The debug GUI must be implemented against OS-native APIs or a Q3A-owned rendering layer. Any exception requires an explicit, recorded change to this policy.
- Public papers, standards, documentation, and observable product behavior may inform requirements. No upstream implementation code or generated implementation artifact may be copied, vendored, linked, or packaged.
- Maintain a source-provenance and license inventory. Q3A acceptance data and expected results must be independently authored or have documented permissions.
- Tests against known expected answers, metamorphic properties, proof-artifact checking, and mathematical invariants are permitted. External formal tools are not test oracles or release dependencies.
- **Implementation language.** C++17 is selected for the Phase 0 prototype. Its portability and build behavior are evaluated during Phase 0; retaining it for the MVP remains an owner decision at Gate B (OD-08).

## 9. Witness Replay and Signal Reconstruction (M8)

M8 is a deterministic evaluator for formal witnesses, not a general-purpose SystemVerilog simulator. It receives a **candidate** witness containing the model states and environment inputs at each formal frame. It replays those frames, validates each frame against T-IR, and evaluates selected T-IR expressions to reconstruct combinational signals that were not stored by the proof engine.

### 9.1 Execution strategy

| Stage | Strategy | Scope |
|---|---|---|
| MVP | Interpreted T-IR evaluator with cached node values per frame | Single-clock, synchronous, two-valued profile; replay and selected-signal reconstruction |
| Later optimization | Q3A-owned bytecode representation and interpreter | Added only if benchmarks show a meaningful benefit without changing semantics |
| Deferred | Native-code or event-driven execution | Requires a separate design review, language-semantic definition, and confirmation that no prohibited runtime dependency is introduced |

The MVP evaluates one transition frame at a time and reuses values within that frame. It may cache selected values or checkpoints under an explicit memory budget. It does not implement a second, independent RTL semantics for simulation.

### 9.2 Replay correctness, validation, and reconstruction

- **Validation.** Every frame of the candidate witness is checked against the lowered transition relation and assumptions **before** it is displayed as a validated counterexample. A frame that fails validation makes the witness invalid: the result reverts to `UNKNOWN` (or `ENGINE_ERROR` if the inconsistency indicates an internal defect), never `FAIL`.
- **Reconstruction.** Reconstructed combinational values are evaluated from the same T-IR and the exact state/input frame. They are labeled **reconstructed**, distinct from values stored directly in the witness.
- **Unmappable signals.** A signal that cannot be mapped or reconstructed is marked unavailable; the tool must not fabricate a source-level value.
- **No re-proof.** Adding a reconstructible signal to a waveform must not require rerunning the proof.
- **Trust boundary.** The trace checker validates the witness against T-IR. Frontend and lowering correctness remain covered by separate source-language conformance tests (§10.3).

## 10. Formal Core

### 10.1 SAT encoding and solver

The MVP bit-blasts the supported two-valued transition model into conjunctive normal form. M10 is a Q3A-owned solver; it must not call an external solver.

The initial solver design should evaluate, rather than assume, the value of these techniques:

| Technique | Full term at first use | Purpose |
|---|---|---|
| Watched literals and BCP | Boolean constraint propagation | Avoid scanning every clause during unit propagation |
| CDCL | Conflict-driven clause learning | Learn clauses from conflicts and use non-chronological backtracking |
| First UIP analysis | Unique implication point | Derive conflict clauses |
| VSIDS | Variable State Independent Decaying Sum | Prioritize decision variables using recent conflict activity |
| LBD | Literal block distance | Estimate learned-clause usefulness and guide retention |
| Restarts and clause deletion | — | Control search behavior and memory use |
| Incremental assumptions | — | Reuse a solver context across related bounded or proof queries |
| Proof artifact and checker | Delete Resolution Asymmetric Tautology (DRAT) is one candidate format | Validate unsatisfiable results using a Q3A-owned checker |

DRAT-style proof logging is a candidate, not a final format decision. Phase 0 must choose an artifact format and demonstrate an independently structured Q3A checker before the solver architecture is frozen. Clause deletion or memory pressure may reduce performance, but must not change satisfiability semantics. If a resource limit is reached, return a non-conclusive status (`RESOURCE_LIMIT`).

### 10.2 Model-checking algorithms

| Algorithm | Method | Valid conclusion |
|---|---|---|
| BMC | Unroll the transition relation through a finite depth and ask whether a violation is satisfiable. | A validated satisfying witness is a counterexample. Unsatisfiable queries only establish **BOUNDED_PASS** through that depth. |
| k-induction | Check the required base prefix and an inductive step under the declared assumptions (§5.3). | **PROVEN** only when both obligations are valid and the proof artifact is accepted. |
| PDR/IC3 | Refine over-approximated reachable-state frames using predecessor queries and inductive clauses. | A validated counterexample or a checked inductive invariant for a safety property. |
| Cover search | Search for a path reaching a cover goal. | A validated witness is **COVERED**. **UNREACHABLE** requires complete reachability evidence. |

PDR is intended as the primary unbounded safety algorithm for the first formal engine. It does not, by itself, solve arbitrary liveness, fairness, multi-clock, memory, or temporal-property semantics. Those require suitable frontend translation and algorithm support.

### 10.3 Proof evidence obligations and trusted computing base

Every conclusive result must be tied to a specific evidence obligation. The table below records, for each obligation, what is **checked** by a Q3A checker and what is **trusted** (the trusted computing base, TCB).

| Evidence obligation | Result it supports | Checked by Q3A checker | Trusted (TCB) |
|---|---|---|---|
| Witness replay | FAIL, COVERED | Each frame satisfies `T` and the assumptions; the failure frame violates the property | T-IR semantics, candidate-witness generation, lowering |
| SAT model | Any SAT-based result | The returned assignment re-evaluates to true under the CNF query | Bit-blaster correctness (T-IR → CNF), CNF query formulation |
| CNF unsatisfiability | BOUNDED_PASS | A DRAT-style proof is checked by the Q3A proof checker | Bit-blaster correctness, proof format, the checker itself |
| k-induction base and step | PROVEN | Both obligations re-established independently of the search | T-IR, assumption semantics, induction formulation |
| PDR invariant | PROVEN | Initiation `S₀ ⊆ F₀`, consecution `Fᵢ ∧ A ∧ T → Fᵢ₊₁′`, and implication `Fₖ → ¬bad` are re-checked | T-IR, assumption semantics, the invariant checker |

The **trusted computing base** includes the source parser, elaborator, SVA compiler, lowering, model semantics (§7), bit-blaster, and proof checker. These components cannot be proven by the checker they underpin. An explicitly versioned corpus records, for every supported source construct, the input, expected elaborated representation, expected T-IR or transition behavior, source-map expectation, and independently authored bounded reference evaluation. Include positive, negative, boundary, reset, and malformed inputs. List metamorphic transformations and the invariant each must preserve. Review expected outputs independently of the implementation under review; external formal tools are not acceptance oracles. Phase 0 reports corpus coverage and remaining gaps.

### 10.4 Checker validation (who checks the checker)

The proof checker (and the invariant checker) must be:

- **Small and structurally separate** from the proof search code, so it can be reviewed independently.
- **Specified by its own contract** (input artifact schema, output verdict, failure modes).
- **Exercised against a corpus of valid and invalid artifacts**: for each checker, the acceptance suite contains at least (a) correctly-formed artifacts that must pass, (b) artifacts with a single injected defect (a flipped literal, a missing clause, a false implication) that must fail, and (c) malformed artifacts that must produce a diagnostic rather than a pass.
- **Deterministic**: the same artifact produces the same verdict.

This closes the regression: the checker is validated by conformance evidence against known-good and known-bad artifacts, not by another checker.

## 11. Proof Management and Resource Scaling

### 11.1 Scheduling policy

- The default low-resource mode is serial and memory-budgeted. A serial execution path is mandatory.
- Independent property queries may run concurrently when the configured CPU and memory budgets allow. The scheduler must avoid unbounded solver duplication.
- Partitioned proof is deferred until cutpoint semantics, boundary assumptions, and proof-composition checks are specified.
- Cone-of-influence (COI) reduction may remove logic only when the dependency slice preserves all dependencies of the property, clocks, resets, initial constraints, and assumptions.
- A solver portfolio may return a result only after its witness or proof artifact passes the applicable Q3A checker.
- Additional processors or memory may improve throughput or prevent resource exhaustion, but the product does not guarantee proportional speedup.
- On resource pressure, the scheduler may pause or stop work and return `RESOURCE_LIMIT`. It must not silently reduce proof depth, change assumptions, or weaken abstraction and report a complete proof.
- A cancellation action produces `CANCELLED` with a recorded cause and a snapshot of completed work.

### 11.2 Reproducibility

Each run records source hashes, manifest, parameters, defines, selected language profile and its version, semantic policies, algorithm, seed, worker count, memory/time limits, Q3A build identifier, and result artifacts.

Re-running an identical configuration must reproduce the same elaborated model and property meaning. Search order, runtime, and the first witness found may differ under parallel scheduling. A timeout or resource-limited status may differ across machines with different limits; such differences must be reported rather than hidden.

Scalability claims require a published benchmark matrix with the hardware profile, design sizes, property counts, time and memory limits, worker counts, and measured results. A speedup claim is limited to the tested workloads.

### 11.3 Cache keys and artifact identity

A proof cache entry is reusable only when every identity component matches. Its key includes:

1. Source files, manifest, parameters, defines, and configuration.
2. Q3A release/build ID and fingerprints for frontend, elaborator, SVA compiler, lowering, bit-blaster, solver, proof checker, and invariant checker.
3. RTL/SVA profile revision and AST, E-IR, T-IR, trace, proof-artifact, and manifest schema versions.
4. Canonical lowered-model bytes and provenance, exact property, assumptions, reset/initial policy, algorithm, depth, options, and seed.
5. Exact generated proof query (including CNF or equivalent canonical query identity) and proof artifact.
6. Imported traces or other external inputs.

A cache hit is not proof evidence. Before reporting a cached conclusive result, a compatible current checker revalidates the artifact against the stored model. Checker or semantic changes invalidate entries unless an explicit compatibility rule applies. Reopening verifies source/model hashes and reports mismatches.

## 12. Trace Format and Debug Interface

### 12.1 Trace generation and storage

The trace pipeline starts from a validated counterexample witness. By default it stores top-level inputs and outputs, clock/reset, property operands, model state, and the exact property dependency slice. Full-design capture is an explicit option.

The native trace format must be versioned and support stable signal identifiers, change-only values, indexed time blocks, checkpoints, selective reads, and lazy loading. It must not require the entire trace to be decompressed or loaded into memory to open a time window. The trace manifest records source mapping, model configuration, property, assumptions, failure frame, and value provenance.

Q3A must implement its own codec. Value Change Dump (VCD) import and export are required for the MVP. Fast Signal Trace (FST) support is optional until the format profile and interoperability acceptance corpus are approved. An external converter is prohibited.

### 12.2 Minimal integrated debug GUI

The MVP GUI provides a compact workflow comparable to the basic property-to-waveform-to-source navigation used by commercial debug environments such as Verdi. This is a workflow reference, not a claim of feature parity.

1. **Property and run panel:** property identifier, status, algorithm, bound or failure frame, assumptions, resource limits, cancellation cause, and run log.
2. **Hierarchy and signal panel:** design hierarchy, signal search, signal selection, and groups for clocks/resets, protocols, CSRs, and property signals.
3. **Waveform and timeline panel:** signal values, cursor, value-at-cursor, zoom, pan, radix selection, transition navigation, and jump-to-failure.
4. **RTL and SVA source panel:** source location, highlighted assertion or signal declaration, and two-way source-to-waveform cross-probing where a valid mapping exists.

On a validated failure, the GUI opens the relevant property, loads its default signal set, places the cursor at the failure frame, and marks reset and assertion events when those events are known. Large traces use viewport rendering, lazy signal/time-block reads, and background indexing. Performance thresholds must be set from measurements on the selected MVP hardware profile.

### 12.3 VCD interchange semantics

VCD is an interchange format, not the source of formal truth. Its import and export behavior is defined as follows.

**Export.** Q3A exports the validated witness to VCD with a declared timescale, cycle indices mapped to timestamps, full hierarchy, signal widths, and the supported two-valued values (0, 1). Export must round-trip losslessly back into the same validated witness.

**Import use cases.** Two cases, never conflated:

1. **Q3A round-trip.** Re-importing a Q3A-exported VCD reconstructs the same trace. This may be used for display and session restore.
2. **External viewing.** Importing an external (non-Q3A) VCD for viewing only. Such a trace is **never** treated as formal evidence and is marked "external, non-formal" in the manifest.

**X/Z and four-state values.** The MVP model is two-valued. On import:

- A VCD value of X or Z is **never silently coerced** to 0 or 1 for formal evidence.
- In a Q3A round-trip, X/Z should not occur (the witness is two-valued); if it does, the import fails with a diagnostic.
- In an external viewing trace, X/Z may be preserved as display-only values, with the trace explicitly marked non-formal and four-state.

**Identifiers, aliases, and duplicates.** Duplicate identifiers and aliases must be detected. If they cannot be resolved unambiguously to distinct signals, the import is rejected with a diagnostic rather than silently merged.

**Timestamp and timescale.** The declared timescale and timestamp precision must be recorded. Cycle-index ↔ timestamp mapping must be exact and preserved across a round-trip. Hierarchy names and widths must round-trip unchanged.

## 13. Public Interfaces

### 13.1 Project manifest schema

The manifest is a versioned text document (proposed: TOML or YAML). Fields include:

- `schema_version` — the manifest schema revision.
- `top` — the top-level design unit.
- `sources` — ordered list of source files with language/kind.
- `include_dirs` — include search paths.
- `defines` — macro definitions and values.
- `parameters` — top-level parameter overrides.
- `properties` — property/bind files.
- `options` — engine, algorithm, depth, seed, resource limits, and profile selection.
- `reset` — reset signal name, polarity, and policy reference (§7.2).

Unknown or unsupported manifest fields produce a diagnostic, not silent acceptance. Parameter precedence is: command-line override > manifest `parameters` > source default.

### 13.2 CLI grammar

The CLI exposes a top-level command with subcommands for the stages that have a user need. Not every module requires a subcommand.

```
q3a elaborate <manifest>   # M1–M5, emit E-IR or diagnostics
q3a prove     <manifest>   # full proof run (default command when <manifest> is a file)
q3a trace     <bundle>     # inspect/export a saved trace bundle
q3a gui       <bundle>     # open the debug GUI on a result bundle
q3a version                # print build and schema versions
q3a help                   # usage
```

Exit codes are stable and documented: `0` conclusive success (proof or validated counterexample), `1` inconclusive (unknown/timeout/resource/cancelled), `2` setup or elaboration failure, `3` engine error. The distinction between "a counterexample was found" and "a proof succeeded" is carried in the result bundle and by a machine-readable summary, not by overloading the exit code.

### 13.3 Result bundle layout

A result bundle is a versioned, integrity-checked directory:

    <run-id>/
      manifest.json           # config, source/build/component hashes, policies, seeds
      summary.json            # per-property result and vacuity metadata
      model/
        model.json            # canonical T-IR, schema, provenance, model hash
      properties/
        <property-id>/
          property.json       # binding, assumptions, exact query identity
          witness.bin         # candidate witness when applicable
          proof.bin           # proof artifact when applicable
          checker-report.json # checker identity and verdict
          log.txt
      trace/                  # native trace, VCD export, and trace manifest
      report/                 # human-readable report
      source-snapshot/        # optional source snapshot; each file hash-verified

The exact model used to produce evidence is always included. A bundle supports inspection of historical results and witness replay without source/model substitution. Rechecking a proof requires a compatible Q3A checker. If unavailable or incompatible, label the result historic and not revalidated by the current executable; never present a stale verdict as current revalidation. Source snapshots may be omitted only when model and source/provenance hashes are present.

### 13.4 Versioning and migration

- Every schema (manifest, native trace, session, IR) carries a `schema_version`.
- A release must read at least the previous `N` schema versions (proposed `N = 1`) and either migrate them losslessly or reject with a clear message.
- Stored debug sessions and traces are covered by the same migration policy; a session that cannot be migrated is rejected, not silently dropped.

## 14. Functional Requirements

The following functional requirements (FRs) are initial, reviewable product requirements. Each identifier (ID) must be traceable to implementation and acceptance evidence. The Q3AF prefix identifies requirements owned by Q3AFormal.

| ID | Requirement |
|---|---|
| Q3AF-FR-001 | Accept a manifest defining the top-level design unit, source order, include paths, macros, parameter overrides, and property sources. |
| Q3AF-FR-002 | Produce a deterministic elaborated configuration and source hash for identical inputs and tool options. |
| Q3AF-FR-003 | Report source-located diagnostics with stable codes, severity, object/property context, and explanatory notes. |
| Q3AF-FR-004 | Classify each language construct as supported, unsupported, or partially supported; reject unsupported semantics before proof. |
| Q3AF-FR-005 | Implement the published MVP SVA profile, including concurrent assert, assume, and cover properties; clock and reset binding; and the explicitly supported sequence operators. |
| Q3AF-FR-006 | Preserve the distinction between assertions, assumptions, and cover goals in the internal model and all reports. |
| Q3AF-FR-007 | Provide BMC, cover search, k-induction, and PDR for the declared supported profile. |
| Q3AF-FR-008 | Return at least PROVEN, FAIL, BOUNDED_PASS, COVERED, UNREACHABLE, UNKNOWN, TIMEOUT, RESOURCE_LIMIT, CANCELLED, UNSUPPORTED, ELABORATION_ERROR, and ENGINE_ERROR. |
| Q3AF-FR-009 | Never assign PROVEN from a finite BMC bound alone; record the algorithm and checked evidence. |
| Q3AF-FR-010 | Save each validated counterexample as a reopenable trace bundle with property, source mapping, failure frame, assumptions, clock/reset context, and model metadata. |
| Q3AF-FR-011 | Record the Q3A build, input hashes, configuration, assumptions, properties, algorithm/options, resource limits, run duration, and per-property result. |
| Q3AF-FR-012 | Detect initial-state and frame-local assumption contradictions when complete checks establish them; report activation-reachability vacuity as complete, bounded, or unavailable with scope and evidence. |
| Q3AF-FR-013 | Report every partition, cutpoint, or abstraction. Do not turn an inconclusive result into PROVEN without a checked soundness argument. |
| Q3AF-FR-014 | Reopen a failed-property run from its saved manifest and trace bundle. |
| Q3AF-FR-015 | Provide a top-level CLI with stable exit codes for completed proof, counterexample, incomplete result, and setup failure. |
| Q3AF-FR-016 | Include the validated witness, waveform, source mapping, assumptions, reset/clock context, and model configuration in the failure bundle. |
| Q3AF-FR-017 | Capture clocks/resets, top-level ports, property operands, and state/control signals in the property dependency slice by default; allow explicit signal expansion. |
| Q3AF-FR-018 | Provide a versioned native trace with indexed blocks and selective reads; implement VCD import/export without an external converter. |
| Q3AF-FR-019 | Provide the integrated debug GUI described in §12. |
| Q3AF-FR-020 | Synchronize property status, failure frame, waveform cursor, and source highlight where a valid source mapping exists. |
| Q3AF-FR-021 | Support failure navigation, signal search, groups, value-at-cursor, zoom/pan, transition navigation, and binary/hexadecimal/decimal display. |
| Q3AF-FR-022 | Save and restore a debug session, including trace reference, selected signals, groups, cursor, markers, and viewport. |
| Q3AF-FR-023 | Read and render large traces selectively; do not require full-trace loading. Acceptance thresholds come from benchmarks. |
| Q3AF-FR-024 | Make the internal GUI sufficient to inspect and navigate Q3A results without an external viewer. |
| Q3AF-FR-025 | Ship without third-party formal, simulation, solver, parser, elaborator, waveform, plugin, or cloud-service runtime dependencies. |
| Q3AF-FR-026 | Keep Q3A-owned implementations for the frontend, proof engine, replay evaluator, trace codecs, checker, and GUI; maintain source provenance. |
| Q3AF-FR-027 | Generate counterexample traces from validated formal witness frames and map values back to the elaborated hierarchy and source where possible. |
| Q3AF-FR-028 | Use event-based storage, indexed blocks, checkpoints, lazy reads, viewport rendering, and background indexing where measurements support them. |
| Q3AF-FR-029 | Provide the integrated property → trace/waveform → RTL/SVA workflow without claiming feature parity with Verdi. |
| Q3AF-FR-030 | Use the same versioned T-IR semantics for proof and witness replay. Label reconstructed values separately from values in the stored witness. |
| Q3AF-FR-031 | Implement the MVP replay evaluator for the synchronous two-valued profile. Any additional execution strategy requires semantic equivalence evidence. |
| Q3AF-FR-032 | Schedule independent property jobs only within explicit resource limits. Parallel execution is optional and does not promise linear speedup. |
| Q3AF-FR-033 | Apply solver memory limits without changing the query semantics. Return RESOURCE_LIMIT or another non-conclusive status when a budget prevents completion. |
| Q3AF-FR-034 | Test every internal module against its typed contract. Expose a diagnostic command only when it has a defined user need; a separate CLI for every module is not required. |
| Q3AF-FR-035 | Record the cause and completed-work snapshot for every CANCELLED run, distinct from UNKNOWN, TIMEOUT, and ENGINE_ERROR. |
| Q3AF-FR-036 | Bind cache validation to source/configuration, Q3A and component/checker builds, semantic/schema versions, canonical model, exact query/evidence, and imported trace, per §11.3. |
| Q3AF-FR-037 | Implement VCD import/export per §12.3: never silently coerce X/Z; mark external four-state traces non-formal; preserve hierarchy, widths, and cycle indices on round-trip. |
| Q3AF-FR-038 | Validate every proof and invariant checker against the valid/invalid/malformed artifact corpus of §10.4. |
| Q3AF-FR-039 | Resolve property attachment and name references per the binding rules of §6.4 and record the exact elaborated signal set of each property. |
| Q3AF-FR-040 | Maintain an independently reviewed source-to-model corpus mapping each supported source construct to expected elaborated and transition behavior, per §10.3. |
| Q3AF-FR-041 | Include the canonical T-IR model, schema, provenance, and integrity hashes in each result bundle; distinguish historic status from current checker revalidation, per §13.3. |
| Q3AF-FR-042 | Include Q3A component/checker identities and canonical model identity in proof-cache validation, per §11.3. |
| Q3AF-FR-043 | Maintain an FR-to-phase-to-acceptance-evidence matrix, per §17.2. |
| Q3AF-FR-044 | Model synchronous reset in every transition frame and preserve unconstrained initial state unless declared initialization or assumptions constrain it, per §7.2. |
| Q3AF-FR-045 | Emit vacuity metadata with explicit completeness scope; never infer complete unreachability from a bounded miss, per §5.3. |

## 15. Language Profiles and Semantic Definitions

The owner-approved Phase 0 profile is a balanced, single-clock, two-valued subset (owner selection recorded 2026-11-15). A construct is supported only when its exact syntax, elaboration, lowering, semantic rule, diagnostic behavior, and positive/negative evidence are recorded in the versioned conformance matrix. Unsupported or incomplete forms are rejected before proof.

### 15.1 Phase 0 RTL profile

#### 15.1.1 Types, literals, and expressions

- **Types and values.** Packed integral values only. The model is two-valued (0 and 1). Four-state X/Z data semantics are unsupported.
- **Unsized decimal literals.** Apply the IEEE 1800 minimum-width, signedness, and expression-context rules; keep these distinct from fill literals.
- **Sized based literals.** Apply declared width and optional signed marker under IEEE 1800 rules. X/Z literal digits are unsupported.
- **Unbased unsized fill literals.** '0 and '1 fill the receiving context with zeroes or ones. 'x and 'z are rejected.
- **Unsized based literals.** Excluded from Phase 0 until exact width/signedness behavior and reviewed conformance vectors are added.
- **Expression operations.** The initial matrix supports unary +, -, !, and ~; binary + and -; bitwise &, |, ^, and ~^; logical && and ||; equality == and !=; relational <, <=, >, and >=; conditional ?:; packed concatenation; constant bit/part selects; and constant-distance << and >>. Case equality/inequality, multiplication/division/modulo, exponentiation, arithmetic right shift, real numbers, dynamic selects, streaming operators, and unlisted operators are unsupported.
- **Sizing and signedness.** Each supported expression form follows IEEE 1800 sizing and signedness rules. The conformance matrix gives operand/result widths, signedness, extension, truncation, and boundary behavior; assignment-context width is not applied indiscriminately.

#### 15.1.2 Structure and processes

Supported forms are module hierarchy and instances; parameter/localparam elaboration; packed integral values; continuous assignment; combinational always_comb; edge-triggered always_ff on the configured positive edge; if/else; case and casez; and static generate if/for with constant elaboration conditions.

Phase 0 module connections require an exact bit-width match between each connected actual and formal port. A mismatch is rejected before transition-model lowering. The frontend must not insert implicit extension or truncation. This is a conservative profile restriction; later profile revisions may add IEEE 1800 port-resizing behavior with dedicated conformance evidence.

Combinational processes use blocking assignments and must assign every output on every path; inferred latches are rejected. Sequential processes use nonblocking assignments. Synchronous reset is modeled in every transition frame per §7.2. No asynchronous reset is supported.

case compares two-valued expressions using exact case-item matching and a default arm when required for complete combinational assignment. casez treats Z and ? bits in static case-item patterns as wildcards, with the first matching item in source order selected. The selector is two-valued; X-valued data and X pattern values are unsupported. unique/priority qualifiers are unsupported unless a separate matrix row defines their checks.

Generic always, interfaces/modports, unions, unpacked/dynamic arrays, memories, classes, DPI, force/release, delays, functions/tasks, and unlisted constructs are unsupported in Phase 0. Black boxes require an explicit model; an unmodeled black box is rejected.

#### 15.1.3 Generate and diagnostics

Generate selection is deterministic for resolved parameter values. Unselected branches are not elaborated. Unsupported syntax and semantics produce source-located diagnostics naming the construct and profile rule. Partial parsing is not a partially valid proof model.

### 15.2 Phase 0 SVA profile

#### 15.2.1 Clock and sampling

The profile supports one explicitly bound positive-edge clock. Concurrent properties sample operands at the preponed sampling point; the cycle model associates those values with S[t] and I[t], with sequential updates forming S[t+1]. Multi-clock properties are unsupported.

#### 15.2.2 Properties, implication, and bounded repetition

Support concurrent assert property, assume property, and cover property; overlapped implication |->; non-overlapped implication |=>; constant nonnegative delay ##N; exact consecutive repetition [*N] with positive compile-time N; and bounded consecutive repetition [*m:n] with compile-time bounds 1 <= m <= n. The owner-approved Phase 0 profile excludes exact zero-count repetition and zero-minimum bounded repetition because empty-sequence cases are outside the selected semantic contract. If an antecedent sequence ends at sample t, |-> starts the consequent at sample t and |=> starts it at the next sample. ##0 has no cycle separation; ##N for N > 0 separates the sequences by N sampled clock cycles. Consecutive repetition matches between the stated minimum and maximum number of adjacent sequence matches.

The profile excludes unbounded repetition, goto repetition [->], nonconsecutive repetition [=], dynamic delays, sequence local variables, liveness/fairness, and unlisted operators. A property is accepted only if its full sequence syntax maps to a reviewed conformance row.

#### 15.2.3 $past and history initialization

Support $past(expression) and $past(expression, N) only for a positive compile-time constant N and the bound profile clock. Other overloads are unsupported.

For $past(expression), the delay is 1. For $past(expression, N), N is a positive compile-time constant and the value at sample t is the operand sampled at t-N. The T-IR introduces a history-valid state for each required delay. It starts false at S[0] and becomes true only after N active clock samples have been captured. A property containing $past is evaluated only when its corresponding history-valid state is true; the initial warm-up cycles are intentionally suppressed by this restricted profile rule. History continues across reset edges because reset does not alter SVA sample history. History data before validity is not assigned a constant. The history-valid state, delay, and warm-up behavior are recorded in the model and result bundle.

Positive, negative, reset, and boundary vectors verify the first valid sample and the N-cycle delay. If the history-valid guard cannot be represented for a property, reject that property before proof.

#### 15.2.4 Unsupported SVA constructs

disable iff is excluded because its asynchronous abort semantics are not in the Phase 0 event model. $stable, $rose, $fell, $changed, multi-clock properties, liveness/fairness, and unlisted SVA syntax are unsupported. The tool must not reinterpret disable iff as a synchronous sampled condition.

### 15.3 Conformance matrix

The versioned matrix contains one row per supported syntax/semantic case: source grammar, elaboration, lowered behavior, source mapping, diagnostics, positive/negative vectors, boundary cases, and limitations. A row is supported only when every evidence field is complete and reviewed. Otherwise it is rejected for this profile. The Phase 0 conformance artifact is q3aformal/prototype/corpus/conformance-matrix.csv, profile Q3A-P0-R0.9.1, aligned to product specification revision 0.10. It records the exact-width port restriction and the remaining syntax-specific profile rules.

## 16. Development Roadmap

### 16.1 Phase 0 — Feasibility and semantic prototype

The owner approved the balanced RTL/SVA subset on 2026-11-15. Prototype implementation follows the approved Phase 0 plan and recorded build/platform decisions. Numeric benchmark thresholds must be approved before measurement.

Activities:

- Publish an independently authored benchmark set and versioned conformance matrix for §15.
- Define source-to-model vectors, expected elaboration/transition representations, independent bounded evaluator, and metamorphic checks.
- Prototype the minimum path: source manager, approved parser/elaborator subset, T-IR, one-clock transition relation, bit-blaster, SAT solver, proof-artifact writer/checker, and candidate-witness replay.
- Demonstrate one known-pass assertion and one known-fail assertion in separate runs. The pass must have checked induction/invariant evidence; the fail must have a replay-validated witness.
- Define bundle and cache identity using exact model/query/build/component/checker/schema fingerprints.
- Measure the approved benchmark on named hardware against thresholds agreed before measurement.

**Exit criteria (Gate B: owner go/no-go).** Phase 0 is complete only with these reviewable artifacts:

1. Frozen benchmark, expected outcomes, source/license provenance, hardware profile, and resource thresholds.
2. Separate known-pass PROVEN run with accepted induction/invariant checker report and known-fail FAIL run with frame-by-frame replay-validated witness.
3. Valid, single-defect invalid, and malformed proof/checker corpus with recorded expected verdicts.
4. Reviewed source-to-model corpus for every prototype construct, including independent bounded evaluation and metamorphic evidence.
5. Result bundle with exact model/evidence identities, no source substitution, and clear distinction between historic and current checker revalidation.
6. Runtime and peak memory measured on named hardware against pre-approved thresholds; all inconclusive outcomes reported.
7. Required owner decisions resolved and a recorded GO or NO-GO. A NO-GO does not proceed to Phase 1.

### 16.2 Phase 1 — MVP for block-level designs

- Stable project manifest, top-level CLI, diagnostics, and published language profiles.
- Q3A-owned SAT solver, BMC, cover, k-induction, and PDR safety proof for the supported model.
- Witness replay evaluator, native trace, VCD import/export, and the four-panel debug GUI.
- No general-purpose testbench simulator, multi-clock execution, or third-party runtime dependency.
- Publish measured correctness, memory, runtime, and trace-navigation results for the frozen benchmark set.

### 16.3 Phase 2 — Subsystem scalability

- Sound partitioning and proof composition with explicit boundary contracts.
- Multi-clock semantics after a dedicated model and scheduling review.
- Exact or soundly abstracted memory support with checked proof obligations.
- Optional property-level parallel scheduling, caching, and resumable work.
- Native equivalence checking only after its state matching and composition semantics are specified.

### 16.4 Phase 3 — Profile and proof expansion

- Extend the RTL/SVA profile using conformance evidence rather than marketing claims.
- Consider four-valued semantics, advanced temporal properties, liveness/fairness, parameter sweeps, and protocol applications only with explicit semantics and acceptance evidence.
- Consider optimized bytecode or other replay execution only when benchmarks justify the implementation cost.

## 17. Acceptance Criteria and Traceability

No performance benchmark is claimed to have been run for this specification. Numeric thresholds must be approved before Phase 0 measurements.

### 17.1 Acceptance criteria

| ID | Criterion |
|---|---|
| Q3AF-AC-01 | Every supported RTL/SVA construct has reviewed positive, negative, boundary, and source-to-model evidence in the versioned conformance matrix (§15.3). |
| Q3AF-AC-02 | Each supported property form has known-true/false outcomes and cycle-alignment evidence; reset/history cases are included where supported. |
| Q3AF-AC-03 | Bounded results, resource limits, cancellation, unsupported constructs, and checker failures are never reported as unbounded proof. |
| Q3AF-AC-04 | Every FAIL witness is checked against exact T-IR and assumptions before presentation. |
| Q3AF-AC-05 | Every PROVEN result has accepted proof evidence for the recorded model, query, assumptions, and compatible checker. |
| Q3AF-AC-06 | Contradictory initial assumptions and frame-local contradictions are reported when complete checks establish them; bounded activation misses are marked incomplete. |
| Q3AF-AC-07 | Replayed and reconstructed values agree with stored witness values where both exist. |
| Q3AF-AC-08 | Identical inputs/options produce the same elaborated model and all result-affecting identities are recorded. |
| Q3AF-AC-09 | Time/memory exhaustion returns a non-conclusive status without changing the query. |
| Q3AF-AC-10 | Scalability results identify hardware, workload, limits, and outcomes. |
| Q3AF-AC-11 | Trace interchange preserves supported values, hierarchy, widths, and cycle indices. |
| Q3AF-AC-12 | Required GUI navigation, source mapping, and session persistence work for supported result bundles. |
| Q3AF-AC-13 | Module contracts and valid/defective/malformed checker cases have recorded evidence. |
| Q3AF-AC-14 | Phase 0 has distinct known-pass PROVEN and known-fail FAIL runs with required evidence. |
| Q3AF-AC-15 | The Phase 0 source-to-model corpus records expected IR/transition behavior and independent evaluation for every prototype construct. |
| Q3AF-AC-16 | Bundles include exact model/build/component/checker identities and never silently substitute inputs. |
| Q3AF-AC-17 | Benchmark runtime/peak memory are compared with thresholds approved before measurement. |
| Q3AF-AC-18 | The command-line interface returns the documented exit codes and machine-readable per-property statuses. |
| Q3AF-AC-19 | Release evidence inventories runtime dependencies and verifies that prohibited third-party engines, parsers, solvers, simulators, and converters are absent. |
| Q3AF-AC-20 | Every functional requirement maps to a phase, acceptance criterion, and evidence artifact; deferred requirements name their release phase. |

### 17.2 FR-to-phase-to-evidence traceability

| Requirement IDs | Planned phase | Acceptance evidence |
|---|---|---|
| Q3AF-FR-001–006, 039–040, 044 | Phase 0 subset; Phase 1 product support | Q3AF-AC-01, 02, 15; conformance matrix and source-to-model corpus |
| Q3AF-FR-007–009, 012–013, 038 | Phase 0 proof/checker subset; Phase 1 engine | Q3AF-AC-03, 05, 06, 13; proof/checker reports |
| Q3AF-FR-010, 014, 016, 027, 030–031 | Phase 0 witness path; Phase 1 product support | Q3AF-AC-04, 07, 14; replay report and trace bundle |
| Q3AF-FR-011, 035–036, 041–042 | Phase 0 evidence format; Phase 1 product support | Q3AF-AC-08, 16; manifest, model hashes, cache revalidation |
| Q3AF-FR-015 | Phase 1 | Q3AF-AC-18; CLI exit-code and machine-readable status evidence |
| Q3AF-FR-019–024, 029 | Phase 1 | Q3AF-AC-12; GUI interaction and persistence evidence |
| Q3AF-FR-017–018, 037 | Phase 1 | Q3AF-AC-11; trace round-trip evidence |
| Q3AF-FR-025–026 | Phase 0 architecture decision; all releases | Q3AF-AC-19; dependency/provenance inventory |
| Q3AF-FR-028, 032–034 | Phase 1; scalability additions in Phase 2 | Q3AF-AC-09, 10, 13; module/resource reports |
| Q3AF-FR-043 | Phase 0 governance artifact | Q3AF-AC-20; reviewed traceability matrix |
| Q3AF-FR-045 | Phase 0 diagnostics; Phase 1 supported scope | Q3AF-AC-06; vacuity metadata/completeness record |

Requirements mapped to later phases are not claimed complete by Phase 0.

## 18. Risks and Open Decisions

| Risk or decision | Required action |
|---|---|
| A complete RTL frontend, SVA compiler, SAT solver, model checker, trace stack, and GUI is a major multi-year effort. | Use the Phase 0 exit criteria (§16.1) to decide whether the architecture is feasible before committing to the complete roadmap. |
| Frontend or lowering defects can invalidate otherwise correct proof search. | Treat parsing, elaboration, and lowering as part of the TCB (§10.3); build conformance suites and source-to-model checks. |
| State-space growth can make useful proofs intractable. | Measure benchmark capacity and report limits; do not imply that PDR or additional memory solves state explosion generally. |
| Memory abstraction can create spurious traces or unsound proofs if mishandled. | Keep exact finite memories in the MVP; require a sound abstraction relation and checked composition before abstract proof claims. |
| Four-state, reset, and multi-clock semantics are easy to misstate. | Restrict the MVP model (§7.2); publish later profiles only after semantic review and acceptance tests. |
| Requiring a self-built GUI and all codecs increases implementation cost. | Keep the MVP interface minimal, make VCD the required interchange format, and add FST only after a clear acceptance case. |
| Low-resource execution may be slow or inconclusive. | Freeze a hardware profile and publish bounded measurements; return non-conclusive statuses at resource limits. |
| Parallel scheduling may increase memory use or vary search artifacts. | Bound worker count and per-job memory; preserve result validity and report nondeterministic search choices. |
| No third-party runtime dependencies constrain portability and GUI choices. | The policy is frozen in §8; any exception requires an explicit, recorded change. |
| C++17 portability and build behavior remain to be measured. | Use C++17 for Phase 0; decide at Gate B whether to retain it for the MVP. |

Owner decisions required before MVP freeze:

- **OD-01:** Maintain the owner-approved balanced Phase 0 RTL/SVA profile (§15); approve any later profile expansion.
- **OD-02:** The owner approved the two-valued initialization and synchronous-reset policy (§7.2) on 2026-11-15.
- **OD-03:** Windows x64 is selected as the Phase 0 development host. Record the exact CPU, memory, OS build, and compiler configuration before benchmark measurement.
- **OD-04:** Approve the native trace schema and decide whether FST is required.
- **OD-05:** Approve proof-artifact and checker format after Phase 0 evidence review.
- **OD-06:** Confirm the third-party dependency boundary (§8), including native OS GUI API acceptability.
- **OD-07:** Approve numeric runtime, memory, design-size, and trace-navigation thresholds before benchmark measurement.
- **OD-08:** C++17 is selected for Phase 0; decide whether to retain it for the product MVP after build and portability evidence.

## 19. Research References

The following sources inform feature requirements and algorithm research. They are not product dependencies. The Q3A implementation and acceptance corpus must remain Q3A-owned.

- [IEEE 1800-2023 SystemVerilog standard](https://standards.ieee.org/ieee/1800/7743/)
- [Bradley, SAT-Based Model Checking Without Unrolling (IC3)](https://theory.stanford.edu/~arbrad/papers/IC3.pdf)
- [Bounded model checking using SAT, Formal Methods in System Design (FMSD)](https://fmv.jku.at/papers/ClarkeBiereRaimiZhu-FMSD-19-1-2001.pdf)
- [k-Induction base and step overview (Kind 2 documentation)](https://kind.cs.uiowa.edu/kind2_user_doc/1_techniques/2_kinduction.html)
- [SymbiYosys workflow and task reference](https://yosyshq.readthedocs.io/projects/sby/en/latest/reference.html)
- [Yosys source project](https://github.com/YosysHQ/yosys)
- [EQY equivalence-checking project](https://github.com/YosysHQ/eqy)
- [slang SystemVerilog compiler](https://github.com/MikePopoloski/slang)
- [Pono model checker](https://github.com/stanford-centaur/pono)
- [Bitwuzla solver](https://github.com/bitwuzla/bitwuzla)
- [DRAT proof format and proof checker research paper](https://arxiv.org/abs/1610.06229)
- [Verilator simulation runtime documentation](https://verilator.org/guide/latest/simulating.html)
- [GTKWave waveform interaction guide](https://github.com/gtkwave/gtkwave/blob/master/docs/quickstart/launching.md)
- [Surfer waveform viewer documentation](https://docs.surfer-project.org/book/)
- Local research comparison: [EVALUATION.md](EVALUATION.md)

## 20. Abbreviations, Status Codes, and Terms

Abbreviations are expanded at their first occurrence in the specification. Product names and project names without a standard expansion are identified as names rather than assigned invented expansions.

| Term | Expansion or definition |
|---|---|
| ABC | Proper name of Berkeley's logic synthesis and verification system; no expansion is assumed here. |
| API | Application programming interface. |
| ASIC | Application-specific integrated circuit. |
| AST | Abstract syntax tree. |
| BMC | Bounded model checking. |
| BCP | Boolean constraint propagation. |
| CDCL | Conflict-driven clause learning. |
| CNF | Conjunctive normal form. |
| CPU | Central processing unit. |
| CSR | Control and status register. |
| cvc5 | Proper name of the SMT solver project; not expanded here. |
| DPI | Direct Programming Interface. |
| DRAT | Delete Resolution Asymmetric Tautology proof format. |
| EDA | Electronic design automation. |
| E-IR | Q3A Elaborated Intermediate Representation. |
| EQY | Proper name of the Yosys equivalence-checking project; not expanded here. |
| FMSD | Formal Methods in System Design, the journal named in the linked BMC paper. |
| FIFO | First-in, first-out. |
| FR | Functional requirement. |
| FST | Fast Signal Trace. |
| FSM | Finite-state machine. |
| GUI | Graphical user interface. |
| IC3 | Incremental Construction of Inductive Clauses for Indubitable Correctness. |
| ID | Identifier. |
| IEEE | Institute of Electrical and Electronics Engineers. |
| IR | Intermediate representation. |
| LBD | Literal block distance. |
| MVP | Minimum viable product. |
| OS | Operating system. |
| PDR | Property-directed reachability. |
| Pono | Proper name of a model-checking project; not expanded here. |
| RAM | Random-access memory. |
| RTL | Register-transfer level. |
| SAT | Boolean satisfiability. |
| SBY | SymbiYosys, the Yosys formal-flow driver. |
| SDF | Standard Delay Format. |
| SMT | Satisfiability modulo theories. |
| SVA | SystemVerilog Assertions. |
| TCB | Trusted computing base. |
| T-IR | Q3A Transition-System Intermediate Representation. |
| UIP | Unique implication point. |
| UVM | Universal Verification Methodology. |
| VCD | Value Change Dump. |
| VSIDS | Variable State Independent Decaying Sum. |
| Z3 | Proper name of an SMT solver; no expansion is assumed here. |
| X / Z | Four-state logic values representing unknown and high impedance, respectively. |
| Q3A | Owner-defined element of the product name; no expansion has been supplied. |
| Q3AF | Q3AFormal functional-requirement identifier prefix. |
| **BOUNDED_PASS** | No counterexample was found up to the reported finite bound; not an unbounded proof. |
| **CANCELLED** | The run was interrupted by an explicit operator or policy action before a conclusive result. |
| **COVERED** | A validated witness reaches the cover goal. |
| **ELABORATION_ERROR** | The project could not be elaborated under the supplied configuration. |
| **ENGINE_ERROR** | An internal consistency or execution failure prevented a valid result. |
| **FAIL** | A property violation has a validated witness. |
| **PROVEN** | A complete proof artifact was checked against the recorded transition-system model. |
| **RESOURCE_LIMIT** | A declared resource budget was reached before a conclusive result. |
| **TIMEOUT** | The time limit expired before a conclusive result. |
| **UNKNOWN** | The run produced neither a validated proof nor a validated counterexample. |
| **UNREACHABLE** | A complete reachability procedure proved that the cover goal cannot be reached. |
| **UNSUPPORTED** | The input uses semantics outside the selected supported profile. |
| **reconstructed value** | A value computed by replay from T-IR and a witness frame. |
| **stored value** | A value explicitly present in the formal witness. |
| **two-valued model** | A model whose logic values are 0 and 1; unknown-value semantics must be defined separately. |
| **four-valued model** | A model whose logic values include 0, 1, X, and Z. |
| S, I, T, S₀ | Mathematical notation for state, input, transition relation, and initial-state set. |










