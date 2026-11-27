# Q3AFormal — Technical Specification

**Status:** Draft for technical review
**Version:** 0.8
**Date:** 2026-11-15
**Purpose:** Define the product scope, architecture, proof semantics, model semantics, language profiles, public interfaces, implementation phases, and acceptance criteria for an independent formal-verification tool for application-specific integrated circuit (ASIC) designs written at the register-transfer level (RTL).

> Revision 0.8 resolves the external review findings R-01 through R-10 and three additional gaps, expands the language profiles into detailed semantic definitions, defines the proof-evidence trust chain, fixes the witness-validation contract, adds reset/initial-state and assumption semantics, defines VCD interchange behavior, adds a CANCELLED status and cache-key policy, specifies public interfaces, and defines Phase 0 exit gates.
>
> "Q3AFormal" is the product name. The owner has not supplied an expansion for "Q3A."

## 1. Executive Summary

Q3AFormal is a proposed formal-verification application for synthesizable RTL and SystemVerilog Assertions (SVA). It will translate a supported RTL and SVA profile into a finite-state model, check properties under explicit environment assumptions, return validated counterexamples, and prove supported safety properties when a complete proof procedure converges.

The intended product is self-contained at runtime. Q3AFormal must implement its own frontend, elaborator, transition-system lowering, Boolean satisfiability (SAT) solver, model-checking algorithms, trace storage, waveform handling, and graphical user interface (GUI). It must not invoke or link third-party electronic design automation (EDA) or formal-verification engines, solvers, simulators, waveform viewers, or converters. External projects listed here are research references only.

The long-term language target is **complete conformance to a published, RTL-focused formal profile**, not an unrestricted implementation of every feature in the Institute of Electrical and Electronics Engineers (IEEE) 1800 SystemVerilog standard. The profile must name supported constructs and semantics. Q3AFormal must reject unsupported constructs rather than ignore or silently simplify them.

The minimum viable product (MVP) is limited to a single-clock, synchronous, two-valued formal model; a published synthesizable RTL subset; and a published concurrent SVA subset. Its debug execution component replays formal witnesses and reconstructs selected signal values. It is not a general-purpose testbench simulator.

## 2. Critical Review Findings and Disposition

This revision addresses the external review report `Q3AFORMAL_SPECIFICATION_REVIEW.md` (findings R-01 through R-10) plus three additional gaps identified during triage.

| Finding | Severity | Disposition in revision 0.8 |
|---|---|---|
| R-01 Freeze the RTL/SVA semantic profile before implementation | Critical | §15 now defines concrete semantic rules for expression sizing/signedness, unsized literals, casts, shifts, indexing, generate, sampling, first-sample, disable, and sampled-value functions. The profile remains a validation target in Phase 0, but the semantics to implement are now written down. |
| R-02 Complete the source-to-proof trust chain | Critical | New §10.3 enumerates five evidence obligations (witness replay, SAT model, CNF UNSAT, k-induction base/step, PDR invariant) and states which components are trusted versus checked. |
| R-03 Resolve the M8 witness-validation contract | High | §6.2 and §9 fixed: M11 emits an *unvalidated candidate witness*; M8 (with the trace checker) validates it against T-IR before display. The circular "validated witness frames" input is removed. |
| R-04 Specify reset and initial-state semantics | Critical | New §7.2 defines a concrete default MVP reset protocol (synchronous, active-high, initial-constraint model) and an uninitialized-state policy. Marked as proposed default pending owner approval. |
| R-05 Define assumptions as part of every proof obligation | High | New §5.3 defines assumption temporal placement (each transition frame, optional initial constraint) and per-engine application (BMC, k-induction, PDR). |
| R-06 Clarify VCD import and four-state handling | High | New §12.3 defines two import use cases, X/Z policy (reject or display-only, never silent coercion), timestamp/identifier/alias handling, and round-trip requirements. |
| R-07 Set the Phase 0 feasibility gate and benchmark protocol | High | New §16.1 defines explicit Phase 0 exit criteria and a go/no-go owner review. |
| R-08 Make reproducibility and cancellation status complete | Medium | §5 adds a CANCELLED status. §11.3 defines cache keys covering semantic-profile version, T-IR schema, proof query, CNF, and imported trace. |
| R-09 Add operational definitions for the public interface | Medium | New §13 specifies the project manifest schema, CLI grammar, result-bundle layout, and versioning/migration policy. |
| R-10 Distinguish product constraints from implementation alternatives | Medium | §8 freezes the dependency boundary (no third-party GUI framework; generic compiler/linker and OS APIs permitted; C++17 provisional until Phase 0). |
| Gap 1 Who validates the proof checker | Medium | New §10.4 defines checker validation: a small, separately specified checker exercised against a corpus of valid and invalid proof artifacts. |
| Gap 2 Assertion/property attachment and binding rules | Medium | New §6.4 defines where properties may live (inline, bound module, top-level) and name-resolution precedence. |
| Gap 3 RESOURCE_LIMIT already introduced in 0.7 | — | Acknowledged; no further action. Remaining taxonomy gap (CANCELLED) is closed by R-08. |

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
- Contradictory assumptions, reset assumptions, black boxes, cutpoints, and memory abstractions must be reported. The tool must warn about vacuity where it can establish that a property antecedent or activation condition is unreachable.
- Every parameter and generate configuration is a distinct proof target unless a separately justified symbolic-parameter method is implemented.

### 5.3 Assumption semantics

Assumptions (`assume property`) restrict the legal environment. Their temporal placement must be identical across every engine and the checker.

- **Scope.** An assumption is a predicate over `(S, I)` at a sampled point. It constrains the environment input `I` at **each transition frame**; if the assumption references state, it additionally constrains the state at that frame.
- **Initial-state application.** By default an assumption applies to every transition frame `t ≥ 0`, including the first. An assumption that must hold only at the initial state is expressed as an initial-state constraint and recorded as such.
- **BMC.** At each unrolled frame `0..k`, the assumption predicate is conjoined with the unrolled transition constraint.
- **k-induction.** The base cases conjoin the assumption at every base frame; the step case conjoins the assumption at each of the `k+1` frames involved in the step obligation.
- **PDR/IC3.** The assumption is folded into the frame relation as a constraint on inputs and state; the inductive invariant's consecution obligation is `Fᵢ ∧ A ∧ T → Fᵢ₊₁′`.
- **Contradictory assumptions.** If an assumption is unsatisfiable (or mutually contradictory with the initial state), every property becomes vacuously true. Q3A must detect or warn on this condition (§17.6).
- **Recorded identity.** The exact assumption set, its encoding, and its placement are part of the run manifest and the proof artifact. The checker must validate evidence under the same assumption semantics.

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

The following is the proposed default. It must be confirmed by the owner before Phase 1 (decision §18.2).

- **Reset type.** Single **synchronous** reset, modeled as an initial-state constraint rather than explicit reset frames. Asynchronous reset is out of MVP scope until its transition semantics are defined.
- **Polarity and name.** Active-high by default; the reset signal name and polarity are declared in the manifest and recorded in the run.
- **Initial-state set S₀.** S₀ is exactly the set of register values assigned by the reset value in the synchronous `always_ff` reset branch. A register with an explicit reset has a fixed S₀ component. A register with **no** reset has an **unconstrained** S₀ component (both 0 and 1 are permitted), which is the sound choice: it does not assume a convenient constant.
- **Reset de-assertion.** The first free (non-reset) cycle is cycle 0 of the trace. Reset assertion is modeled as holding at cycle 0 (the initial constraint); the reset signal itself may be an input whose assertion is recorded but, for the synchronous model, does not add transition frames beyond the initial constraint.
- **Clock.** One synchronous clock, sampling on the positive edge (configurable). The sampled value of a signal is its value settled before the clock edge (the preponed-region value), which for a synchronous two-valued model equals the state value entering the transition.
- **Acceptance corpus.** Must include reset-held, reset-released, missing-reset, and contradictory-reset-assumption cases, plus a case proving that uninitialized state is treated as unconstrained (not as a constant).

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
- **Implementation language.** C++17 is the provisional implementation language. It remains provisional until the Phase 0 prototype validates build, portability, and memory behavior (decision §18.8).

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

The **trusted computing base** includes: the source parser, elaborator, SVA compiler, lowering, the model semantics (§7), the bit-blaster, and the proof checker itself. These components cannot be "proven" by the checker they underpin; they are validated by conformance suites, source-to-model checks, and metamorphic tests. Release claims must describe this boundary rather than imply that a proof checker validates the complete source-language implementation.

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

Cached and replayed artifacts must be tied unambiguously to the exact semantics and source snapshot that produced them. The cache key for a proof result includes, at minimum, hashes of:

1. The source files and manifest (already recorded).
2. The **semantic profile version** (which conformance matrix revision applied).
3. The **T-IR schema version** and the **E-IR/AST schema versions**.
4. The **proof query** (property encoding, assumptions, reset/init policy, depth, algorithm, options, seed).
5. The **generated CNF** (or the bit-blaster configuration that deterministically produces it).
6. Any **imported trace** used as an input.

A portable result bundle must either embed the source snapshot (verified by hash) or require a source tree whose hash matches the recorded value. Reopening a run must not silently substitute a different source tree.

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

A result bundle is a versioned directory:

```
<run-id>/
  manifest.json          # run manifest: config, hashes, versions, policies, seeds
  summary.json           # per-property status and evidence pointers
  properties/            # per-property artifacts (witness, proof artifact, log)
  trace/                 # native trace + VCD/FST export + trace manifest
  report/                # human-readable report
  source-snapshot/       # optional embedded source snapshot (hash-verified)
```

The bundle is self-describing through `manifest.json`; a consumer must be able to reopen any `FAIL`, `PROVEN`, or `COVERED` result from the bundle alone (or from the bundle plus a hash-matching source tree).

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
| Q3AF-FR-012 | Provide checks for contradictory assumptions and property vacuity, with limitations stated in the result. |
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
| Q3AF-FR-036 | Compute cache keys for proof results from the semantic-profile version, IR schema versions, proof query, generated CNF, and imported trace, per §11.3. |
| Q3AF-FR-037 | Implement VCD import/export per §12.3: never silently coerce X/Z; mark external four-state traces non-formal; preserve hierarchy, widths, and cycle indices on round-trip. |
| Q3AF-FR-038 | Validate every proof and invariant checker against the valid/invalid/malformed artifact corpus of §10.4. |
| Q3AF-FR-039 | Resolve property attachment and name references per the binding rules of §6.4 and record the exact elaborated signal set of each property. |

## 15. Language Profiles and Semantic Definitions

This section defines the concrete semantics that Phase 0 must implement and validate. A construct is "supported" only when parsing, elaboration, lowering, and the semantic rules below are all implemented with conformance evidence.

### 14.1 MVP RTL profile

#### 14.1.1 Expression semantics

- **Sizing.** Expression sizing follows IEEE 1800 context-determined rules: an assignment target's width determines the right-hand side width (with sign extension or truncation as appropriate); self-determined sub-expressions size independently before combination.
- **Signedness.** Signedness propagates according to IEEE 1800 rules: if any operand of a binary arithmetic operator is unsigned, the result is unsigned; relational and equality operators define their own rules. `$signed` and `$unsigned` force the interpretation.
- **Unsized literals.** Unsized constant numbers (e.g., `'hF`, `'d3`, `'1`) are signed and sized to the expression context (IEEE 1800 §5.7). Unsized fill literals `'0`, `'1`, `'x`, `'z` fill the context width. The two-valued MVP treats `'x` and `'z` fill as unsupported (they require four-valued semantics) and rejects them unless a documented two-valued interpretation is adopted.
- **Casts.** Size casting `size'(expr)` truncates or extends; type casting and `$signed`/`$unsigned` are supported where their semantics are defined.
- **Shifts.** Logical shift `<<`/`>>` shifts and zero-fills; arithmetic shift `>>>` sign-extends. A shift count wider than the operand, or a negative shift count, is handled per IEEE 1800 (which defines the result for these cases); the MVP must implement and test those boundary cases.
- **Indexing.** Packed vector indexing selects bits/part-selects; unpacked array indexing selects elements. Out-of-bounds indexing in the two-valued MVP is rejected at elaboration (static) or defined explicitly (dynamic); it must not silently yield a constant.

#### 14.1.2 Structural and process semantics

- `always_ff` for synchronous registers, `always_comb` for combinational logic, `always` where its synthesizable semantics are defined; continuous `assign`; packed vectors; `enum`; selected `struct`/`union` within backend capability; bounded arrays and memories; synthesizable `function`/`task`; `generate` (if/case/for); `parameter`/`localparam`; `package` and an interface subset.
- **Generate resolution** must be deterministic: the same parameter configuration always selects the same generate branch; conditional generate branches that are not selected are not elaborated.
- **Black boxes and primitive cells** require an explicit, recorded modeling policy; an unmodeled black box is not silently treated as unconstrained.

#### 14.1.3 Unsupported RTL constructs

Dynamic objects, classes, DPI, force/release, and non-synthesizable delays must produce a diagnostic and must not be assumed to have no effect on the model.

### 14.2 MVP SVA profile

#### 14.2.1 Sampling and clocking

- Concurrent assertions sample in the **preponed region** (IEEE 1800 §16.5.1): the sampled value of a signal at a time step is the value settled before that time step's NBA region. For the synchronous two-valued cycle model, this is the state value entering the transition.
- The MVP supports a single positive-edge clock `@(posedge clk)`. Multi-clock properties are unsupported.
- **Reset disable** uses `disable iff` with defined semantics: when the disable condition is true at a sampled point, the property attempt is disabled (neither passes nor fails for that attempt). The MVP must define and test the interaction between `disable iff` and the synchronous reset model.

#### 14.2.2 Sequences and operators

- `assert property`, `assume property`, `cover property`, and concurrent assertion declarations.
- `|->` overlapped implication (consequent starts in the same cycle as the antecedent) and `|=>` non-overlapped implication (consequent starts in the next cycle).
- `##N` sequence concatenation with constant `N`; bounded repetition `[*m:n]`, `[=m:n]`, `[->m:n]` within the selected subset.
- **First-sample semantics.** For a sequence or sampled-value function referencing a prior cycle before enough samples exist: `$past(x, n)` returns the declared default (the initial value of `x` or a specified default); `$rose`/`$fell`/`$stable`/`$changed` are false (or use the declared default) when no prior sample exists. These defaults must be defined and tested.

#### 14.2.3 Sampled-value functions

`$past`, `$stable`, `$rose`, `$fell`, and `$changed` are supported with defined initialization/first-sample semantics (§15.2.2).

#### 14.2.4 Unsupported SVA constructs

Unbounded repetition, multi-clock properties, complex local variables, advanced sequence operators (`first_match`, `throughout`, `within`, `intersect`, `until`), dynamic delays, and liveness/fairness properties remain unsupported until their translations and proof algorithms are validated.

### 14.3 Conformance matrix

Each construct in §15.1–§15.2 must have a conformance row:

| Construct | Parse | Elaborate | Lower | Semantic tests (positive/negative) | Known limitations |
|---|---|---|---|---|---|

A construct is marked "supported" only when all columns are complete. A construct with any empty column is "partially supported" or "unsupported" and must be rejected before proof, not silently ignored.

## 16. Development Roadmap

### 15.1 Phase 0 — Feasibility and semantic prototype

Activities:

- Freeze a small, independently authored set of known-pass and known-fail designs.
- Define the first RTL/SVA conformance profile against IEEE 1800-2023 and implement the semantic rules in §15.
- Prototype the source manager, parser, elaborator, T-IR, one-clock lowering, bit-blaster, SAT solver, and proof checker.
- Demonstrate one assertion from source through transition model, proof query, validated witness, replay, and source mapping.
- Choose and implement a proof-artifact format with an independently structured Q3A checker (§10.4).
- Specify the baseline hardware and benchmark protocol before making resource claims.

**Exit criteria (go/no-go gate).** Phase 0 is complete only when all of the following hold, verified in an owner review:

1. The frozen benchmark set is named and has known-pass and known-fail expected outcomes.
2. At least one assertion is demonstrated end-to-end with a validated witness and a checked proof artifact.
3. The proof checker passes the valid/invalid artifact corpus (§10.4).
4. Peak memory and runtime for the benchmark set are measured on a named hardware profile and are within declared, non-guessed thresholds.
5. The C++17 build, portability, and memory behavior are validated (or the language is changed by an owner decision).
6. A go/no-go owner decision is recorded. A "no-go" does not proceed to Phase 1.

### 15.2 Phase 1 — MVP for block-level designs

- Stable project manifest, top-level CLI, diagnostics, and published language profiles.
- Q3A-owned SAT solver, BMC, cover, k-induction, and PDR safety proof for the supported model.
- Witness replay evaluator, native trace, VCD import/export, and the four-panel debug GUI.
- No general-purpose testbench simulator, multi-clock execution, or third-party runtime dependency.
- Publish measured correctness, memory, runtime, and trace-navigation results for the frozen benchmark set.

### 15.3 Phase 2 — Subsystem scalability

- Sound partitioning and proof composition with explicit boundary contracts.
- Multi-clock semantics after a dedicated model and scheduling review.
- Exact or soundly abstracted memory support with checked proof obligations.
- Optional property-level parallel scheduling, caching, and resumable work.
- Native equivalence checking only after its state matching and composition semantics are specified.

### 15.4 Phase 3 — Profile and proof expansion

- Extend the RTL/SVA profile using conformance evidence rather than marketing claims.
- Consider four-valued semantics, advanced temporal properties, liveness/fairness, parameter sweeps, and protocol applications only with explicit semantics and acceptance evidence.
- Consider optimized bytecode or other replay execution only when benchmarks justify the implementation cost.

## 17. Acceptance Criteria

No performance benchmark is claimed to have been run for this specification. Acceptance thresholds must be agreed before the MVP release.

1. **Language conformance:** each supported construct has positive and negative parsing, elaboration, and semantic cases per §15.3.
2. **Property semantics:** each supported assertion and sequence construct has known-true, known-false, reset, first-sample, and boundary-frame cases where applicable.
3. **Status soundness:** bounded results, resource limits, cancellation, and unsupported constructs cannot be reported as unbounded proofs.
4. **Witness validity:** each FAIL witness is checked against T-IR and assumptions; waveform values match the witness.
5. **Proof evidence:** every PROVEN artifact passes the Q3A checker for the recorded model, per §10.3.
6. **Assumption and vacuity diagnostics:** contradictory assumptions and unreachable property activation are detected or reported as a known limitation.
7. **Replay consistency:** replayed and reconstructed values agree with stored witness values whenever both exist.
8. **Reproducibility:** identical inputs and options produce the same elaborated model; run manifests capture all settings that can affect proof search, including semantic-profile and schema versions.
9. **Resource behavior:** exceeding a time or memory budget yields a non-conclusive status without changing the query.
10. **Scalability reporting:** report runtime and peak memory for each published design and hardware profile; do not generalize beyond the measured workload.
11. **Trace fidelity:** export/import preserves timestamps or cycle indices, hierarchy, widths, and supported logic values, per §12.3.
12. **Trace scalability:** measure trace creation, open, seek, viewport render, search, and peak memory on short and large traces.
13. **Debug workflow:** a failed property opens the right trace, failure frame, and source location when mappings exist.
14. **Session persistence:** reopening a saved session restores the selected signals, groups, cursor, markers, and viewport.
15. **Module contracts:** every internal module has isolated contract tests. Only required diagnostic commands are exposed.
16. **Checker validation:** each checker passes the valid/invalid/malformed artifact corpus of §10.4.
17. **VCD round-trip:** a Q3A-exported VCD re-imports to the same validated witness without loss of values, hierarchy, widths, or cycle indices.

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
| C++17 is not supported by a recorded feasibility decision. | Keep it provisional until the Phase 0 prototype validates implementation, portability, and build constraints. |

Owner decisions required before MVP freeze:

1. Approve the precise RTL and SVA conformance profiles (§15).
2. Approve the two-valued initialization and reset policy (§7.2).
3. Select the first operating system and baseline hardware profile.
4. Approve the native trace schema and decide whether FST is required.
5. Approve the proof artifact and checker format after the Phase 0 prototype.
6. Confirm the frozen third-party dependency boundary (§8), including whether native OS GUI APIs are acceptable.
7. Approve measurable runtime, memory, design-size, and trace-navigation targets from benchmark results.
8. Confirm whether C++17 remains the implementation language after the feasibility review.

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
