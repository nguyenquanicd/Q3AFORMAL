from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[2]
source = root / "Q3AFORMAL_SPECIFICATION.md"
out = root / "q3aformal/specs/002-phase0-feasibility/proposed/Q3AFORMAL_SPECIFICATION_v0.9.md"
s = source.read_text(encoding="utf-8")

def section(doc, start, end, body):
    a = doc.index(start)
    b = doc.index(end, a)
    return doc[:a] + body.rstrip() + "\n\n" + doc[b:]

s = s.replace("**Status:** Draft for technical review", "**Status:** Draft for technical review; Phase 0 RTL/SVA subset selected by owner", 1)
s = s.replace("**Version:** 0.8", "**Version:** 0.9", 1)
s = s.replace(
"> Revision 0.8 resolves the external review findings R-01 through R-10 and three additional gaps, expands the language profiles into detailed semantic definitions, defines the proof-evidence trust chain, fixes the witness-validation contract, adds reset/initial-state and assumption semantics, defines VCD interchange behavior, adds a CANCELLED status and cache-key policy, specifies public interfaces, and defines Phase 0 exit gates.",
"> Revision 0.9 incorporates the approved disposition of Q3A-SPEC-001 through Q3A-SPEC-011. The owner approved the balanced Phase 0 RTL/SVA subset on 2026-11-15. Exact implementation language, baseline platform, and numeric benchmark thresholds remain pending where not specified below.",
1)
s = section(s, "## 2. Critical Review Findings and Disposition", "## 3. Product Goals and Design Principles", """## 2. Review Findings and Disposition

This revision incorporates the approved recommendations from the independent specification review.

| Finding | Severity | Disposition in revision 0.9 |
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
| Q3A-SPEC-011: vacuity scope | Medium | §5.3 defines contradiction checks and completeness labels for vacuity analysis. |""")
s = section(s, "### 7.2 Reset and initial-state semantics (proposed MVP default)", "### 7.3 Memory policy", """### 7.2 Reset and initial-state semantics (proposed MVP default)

The owner-approved default models reset in the transition relation, not as an initial-state substitute.

- **Cycle model.** State S[t] is the state immediately before active clock edge t. Inputs, including reset, are sampled at that edge. The transition relation computes S[t+1].
- **Synchronous reset.** Reset is evaluated at every active clock edge and is included in T(S[t], I[t], S[t+1]). If reset is asserted at edge t, each register with a synchronous reset assignment takes that value in S[t+1]. Reset may remain asserted or be reasserted later.
- **Reset configuration.** The manifest declares reset signal, polarity, and clock edge. The Phase 0 profile uses one positive-edge clock and one synchronous reset. Asynchronous reset is outside the approved Phase 0 subset.
- **Initial states.** Unless a supported RTL initialization construct or explicit initial assumption constrains them, state bits are unconstrained in S[0]. Synchronous reset does not constrain S[0] before its first active edge.
- **Unreset state.** Registers without reset assignments remain unconstrained initially and evolve according to their transition logic.
- **Clock and assertion sampling.** Concurrent properties sample preponed values at the active edge, corresponding to S[t] and I[t]; sequential RTL updates produce S[t+1].
- **Reset assumptions.** Any startup protocol is an explicit environment assumption in the manifest and proof obligation. No startup reset is silently assumed.
- **Acceptance evidence.** Separate cases cover reset held for multiple edges, release, later reassertion, missing reset, and unconstrained initial state. Cases verify both state transition and property sampling.""")
s = s.replace(
"- **Contradictory assumptions.** If an assumption is unsatisfiable (or mutually contradictory with the initial state), every property becomes vacuously true. Q3A must detect or warn on this condition (§17.6).",
"- **Guaranteed contradiction checks.** Detect an unsatisfiable initial-state constraint set and frame-local contradictory assumptions when the corresponding SAT query is complete. Record checked scope and evidence. If no legal initial state exists, do not present downstream property results as functional coverage.",
1)
s = s.replace(
"The exact assumption set, its encoding, and its placement are part of the run manifest and the proof artifact. The checker must validate evidence under the same assumption semantics.",
"The exact assumption set, its encoding, and placement are part of the run manifest and proof artifact. The checker validates evidence under the same semantics. Vacuity is separate metadata, not a substitute proof status: report DETECTED, NOT_DETECTED_WITHIN_SCOPE, or INCOMPLETE. A bounded search with no property activation is only an incomplete warning; it cannot establish complete unreachability. Record the depth or completeness procedure.",
1)
s = s.replace(
"The **trusted computing base** includes: the source parser, elaborator, SVA compiler, lowering, the model semantics (§7), the bit-blaster, and the proof checker itself. These components cannot be \"proven\" by the checker they underpin; they are validated by conformance suites, source-to-model checks, and metamorphic tests. Release claims must describe this boundary rather than imply that a proof checker validates the complete source-language implementation.",
"""The **trusted computing base** includes the source parser, elaborator, SVA compiler, lowering, model semantics (§7), bit-blaster, and proof checker. These components cannot be proven by the checker they underpin. An explicitly versioned corpus records, for every supported source construct, the input, expected elaborated representation, expected T-IR or transition behavior, source-map expectation, and independently authored bounded reference evaluation. Include positive, negative, boundary, reset, and malformed inputs. List metamorphic transformations and the invariant each must preserve. Review expected outputs independently of the implementation under review; external formal tools are not acceptance oracles. Phase 0 reports corpus coverage and remaining gaps.""",
1)
s = section(s, "### 11.3 Cache keys and artifact identity", "## 12. Trace Format and Debug Interface", """### 11.3 Cache keys and artifact identity

A proof cache entry is reusable only when every identity component matches. Its key includes:

1. Source files, manifest, parameters, defines, and configuration.
2. Q3A release/build ID and fingerprints for frontend, elaborator, SVA compiler, lowering, bit-blaster, solver, proof checker, and invariant checker.
3. RTL/SVA profile revision and AST, E-IR, T-IR, trace, proof-artifact, and manifest schema versions.
4. Canonical lowered-model bytes and provenance, exact property, assumptions, reset/initial policy, algorithm, depth, options, and seed.
5. Exact generated proof query (including CNF or equivalent canonical query identity) and proof artifact.
6. Imported traces or other external inputs.

A cache hit is not proof evidence. Before reporting a cached conclusive result, a compatible current checker revalidates the artifact against the stored model. Checker or semantic changes invalidate entries unless an explicit compatibility rule applies. Reopening verifies source/model hashes and reports mismatches.""")
s = section(s, "### 13.3 Result bundle layout", "### 13.4 Versioning and migration", """### 13.3 Result bundle layout

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

The exact model used to produce evidence is always included. A bundle supports inspection of historical results and witness replay without source/model substitution. Rechecking a proof requires a compatible Q3A checker. If unavailable or incompatible, label the result historic and not revalidated by the current executable; never present a stale verdict as current revalidation. Source snapshots may be omitted only when model and source/provenance hashes are present.""")
s = s.replace(
"Contradictory assumptions, reset assumptions, black boxes, cutpoints, and memory abstractions must be reported. The tool must warn about vacuity where it can establish that a property antecedent or activation condition is unreachable.",
"Contradictory assumptions, reset assumptions, black boxes, cutpoints, memory abstractions, and vacuity-analysis scope must be reported. Complete claims of unreachable property activation require complete reachability evidence; bounded misses are labeled incomplete.")
s = s.replace(
"| Q3AF-FR-012 | Provide checks for contradictory assumptions and property vacuity, with limitations stated in the result. |",
"| Q3AF-FR-012 | Detect initial-state and frame-local assumption contradictions when complete checks establish them; report activation-reachability vacuity as complete, bounded, or unavailable with scope and evidence. |")
s = s.replace(
"| Q3AF-FR-036 | Compute cache keys for proof results from the semantic-profile version, IR schema versions, proof query, generated CNF, and imported trace, per §11.3. |",
"| Q3AF-FR-036 | Bind cache validation to source/configuration, Q3A and component/checker builds, semantic/schema versions, canonical model, exact query/evidence, and imported trace, per §11.3. |")
marker = "| Q3AF-FR-039 | Resolve property attachment and name references per the binding rules of §6.4 and record the exact elaborated signal set of each property. |"
extra = """| Q3AF-FR-040 | Maintain an independently reviewed source-to-model corpus mapping each supported source construct to expected elaborated and transition behavior, per §10.3. |
| Q3AF-FR-041 | Include the canonical T-IR model, schema, provenance, and integrity hashes in each result bundle; distinguish historic status from current checker revalidation, per §13.3. |
| Q3AF-FR-042 | Include Q3A component/checker identities and canonical model identity in proof-cache validation, per §11.3. |
| Q3AF-FR-043 | Maintain an FR-to-phase-to-acceptance-evidence matrix, per §17.2. |
| Q3AF-FR-044 | Model synchronous reset in every transition frame and preserve unconstrained initial state unless declared initialization or assumptions constrain it, per §7.2. |
| Q3AF-FR-045 | Emit vacuity metadata with explicit completeness scope; never infer complete unreachability from a bounded miss, per §5.3. |"""
s = s.replace(marker, marker + "\n" + extra, 1)

s = section(s, "## 15. Language Profiles and Semantic Definitions", "## 16. Development Roadmap", """## 15. Language Profiles and Semantic Definitions

The owner-approved Phase 0 profile is a balanced, single-clock, two-valued subset. A construct is supported only when its exact syntax, elaboration, lowering, semantic rule, diagnostic behavior, and positive/negative evidence are recorded in the versioned conformance matrix. Unsupported or incomplete forms are rejected before proof.

### 15.1 Phase 0 RTL profile

#### 15.1.1 Types, literals, and expressions

- **Types and values.** Packed integral values only. The model is two-valued (0 and 1). Four-state X/Z data semantics are unsupported.
- **Unsized decimal literals.** Apply the IEEE 1800 minimum-width, signedness, and expression-context rules; keep these distinct from fill literals.
- **Sized based literals.** Apply declared width and optional signed marker under IEEE 1800 rules. X/Z literal digits are unsupported.
- **Unbased unsized fill literals.** '0 and '1 fill the receiving context with zeroes or ones. 'x and 'z are rejected.
- **Unsized based literals.** Excluded from Phase 0 until exact width/signedness behavior and reviewed conformance vectors are added.
- **Expression operations.** Support unary sign/logical/bitwise operators; addition and subtraction; bitwise and logical operators; equality and relational comparisons; conditional expressions; concatenation; constant bit/part selects; and constant shifts left/right. Multiplication, division, real numbers, dynamic selects, and unlisted operators are unsupported.
- **Sizing and signedness.** Each supported expression form follows IEEE 1800 sizing and signedness rules. The conformance matrix gives operand/result widths, signedness, extension, truncation, and boundary behavior; assignment-context width is not applied indiscriminately.

#### 15.1.2 Structure and processes

Supported forms are module hierarchy and instances; parameter/localparam elaboration; packed integral values; continuous assignment; combinational always_comb; edge-triggered always_ff on the configured positive edge; if/else; case and casez; and static generate if/for with constant elaboration conditions.

Combinational processes use blocking assignments and must assign every output on every path; inferred latches are rejected. Sequential processes use nonblocking assignments. Synchronous reset is modeled in every transition frame per §7.2. No asynchronous reset is supported.

case compares two-valued expressions using exact case-item matching. casez supports Z and ? wildcard bits in static case-item patterns; X-valued data and X pattern values are unsupported. unique/priority qualifiers are unsupported unless a separate matrix row defines their checks.

Generic always, interfaces/modports, unions, unpacked/dynamic arrays, memories, classes, DPI, force/release, delays, functions/tasks, and unlisted constructs are unsupported in Phase 0. Black boxes require an explicit model; an unmodeled black box is rejected.

#### 15.1.3 Generate and diagnostics

Generate selection is deterministic for resolved parameter values. Unselected branches are not elaborated. Unsupported syntax and semantics produce source-located diagnostics naming the construct and profile rule. Partial parsing is not a partially valid proof model.

### 15.2 Phase 0 SVA profile

#### 15.2.1 Clock and sampling

The profile supports one explicitly bound positive-edge clock. Concurrent properties sample operands at the preponed sampling point; the cycle model associates those values with S[t] and I[t], with sequential updates forming S[t+1]. Multi-clock properties are unsupported.

#### 15.2.2 Properties, implication, and bounded repetition

Support concurrent assert property, assume property, and cover property; overlapped implication |->; non-overlapped implication |=>; constant nonnegative delay ##N; and consecutive bounded repetition [*N] and [*m:n] with compile-time constant bounds.

The profile excludes unbounded repetition, goto repetition [->], nonconsecutive repetition [=], dynamic delays, sequence local variables, liveness/fairness, and unlisted operators. A property is accepted only if its full sequence syntax maps to a reviewed conformance row.

#### 15.2.3 $past and history initialization

Support $past(expression) and $past(expression, N) only for a positive compile-time constant N and the bound profile clock. Other overloads are unsupported.

The T-IR introduces a history-valid state for the maximum requested delay. It is false initially and becomes true after enough active clock samples have been captured. A property containing $past is evaluated only when the corresponding history-valid state is true; the initial warm-up cycles are explicitly suppressed by this profile rule. History data before validity is not assigned a convenient constant. The history-valid state, delay, and warm-up behavior are recorded in the model and result bundle.

Positive, negative, reset, and boundary vectors verify the first valid sample and the N-cycle delay. If the history-valid guard cannot be represented for a property, reject that property before proof.

#### 15.2.4 Unsupported SVA constructs

disable iff is excluded because its asynchronous abort semantics are not in the Phase 0 event model. $stable, $rose, $fell, $changed, multi-clock properties, liveness/fairness, and unlisted SVA syntax are unsupported. The tool must not reinterpret disable iff as a synchronous sampled condition.

### 15.3 Conformance matrix

The versioned matrix contains one row per supported syntax/semantic case: source grammar, elaboration, lowered behavior, source mapping, diagnostics, positive/negative vectors, boundary cases, and limitations. A row is supported only when every evidence field is complete and reviewed. Otherwise it is rejected for this profile.""")
# Correct obsolete section numbering in the new hierarchy.
s = s.replace("### 15.1 Phase 0 — Feasibility and semantic prototype", "### 16.1 Phase 0 — Feasibility and semantic prototype")
s = s.replace("### 15.2 Phase 1 — MVP for block-level designs", "### 16.2 Phase 1 — MVP for block-level designs")
s = s.replace("### 15.3 Phase 2 — Subsystem scalability", "### 16.3 Phase 2 — Subsystem scalability")
s = s.replace("### 15.4 Phase 3 — Profile and proof expansion", "### 16.4 Phase 3 — Profile and proof expansion")
s = section(s, "### 16.1 Phase 0 — Feasibility and semantic prototype", "### 16.2 Phase 1 — MVP for block-level designs", """### 16.1 Phase 0 — Feasibility and semantic prototype

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
7. Required owner decisions resolved and a recorded GO or NO-GO. A NO-GO does not proceed to Phase 1.""")
s = section(s, "## 17. Acceptance Criteria", "## 18. Risks and Open Decisions", """## 17. Acceptance Criteria and Traceability

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

### 17.2 FR-to-phase-to-evidence traceability

| Requirement IDs | Planned phase | Acceptance evidence |
|---|---|---|
| Q3AF-FR-001–006, 039–040, 044 | Phase 0 subset; Phase 1 product support | Q3AF-AC-01, 02, 15; conformance matrix and source-to-model corpus |
| Q3AF-FR-007–009, 012–013, 038 | Phase 0 proof/checker subset; Phase 1 engine | Q3AF-AC-03, 05, 06, 13; proof/checker reports |
| Q3AF-FR-010, 014, 016, 027, 030–031 | Phase 0 witness path; Phase 1 product support | Q3AF-AC-04, 07, 14; replay report and trace bundle |
| Q3AF-FR-011, 035–036, 041–042 | Phase 0 evidence format; Phase 1 product support | Q3AF-AC-08, 16; manifest, model hashes, cache revalidation |
| Q3AF-FR-015, 019–024, 029 | Phase 1 | Q3AF-AC-12 plus CLI/status acceptance evidence |
| Q3AF-FR-017–018, 037 | Phase 1 | Q3AF-AC-11; trace round-trip evidence |
| Q3AF-FR-025–026 | Phase 0 architecture decision; all releases | Dependency/provenance inventory |
| Q3AF-FR-028, 032–034 | Phase 1; scalability additions in Phase 2 | Q3AF-AC-09, 10, 13; module/resource reports |
| Q3AF-FR-043 | Phase 0 governance artifact | Reviewed traceability matrix |
| Q3AF-FR-045 | Phase 0 diagnostics; Phase 1 supported scope | Q3AF-AC-06; vacuity metadata/completeness record |

Requirements mapped to later phases are not claimed complete by Phase 0.""")
s = s.replace("§17.6", "§17.1, Q3AF-AC-06")
s = s.replace("decision §18.2", "Owner Decision OD-02 in §18")
s = s.replace("decision §18.8", "Owner Decision OD-08 in §18")
s = s.replace(
"Owner decisions required before MVP freeze:\n\n1. Approve the precise RTL and SVA conformance profiles (§15).\n2. Approve the two-valued initialization and reset policy (§7.2).\n3. Select the first operating system and baseline hardware profile.\n4. Approve the native trace schema and decide whether FST is required.\n5. Approve the proof artifact and checker format after the Phase 0 prototype.\n6. Confirm the frozen third-party dependency boundary (§8), including whether native OS GUI APIs are acceptable.\n7. Approve measurable runtime, memory, design-size, and trace-navigation targets from benchmark results.\n8. Confirm whether C++17 remains the implementation language after the feasibility review.",
"""Owner decisions required before MVP freeze:

- **OD-01:** Maintain the owner-approved balanced Phase 0 RTL/SVA profile (§15); approve any later profile expansion.
- **OD-02:** The owner approved the two-valued initialization and synchronous-reset policy (§7.2) on 2026-11-15.
- **OD-03:** Select and record the first operating system and baseline hardware profile before benchmark measurement.
- **OD-04:** Approve the native trace schema and decide whether FST is required.
- **OD-05:** Approve proof-artifact and checker format after Phase 0 evidence review.
- **OD-06:** Confirm the third-party dependency boundary (§8), including native OS GUI API acceptability.
- **OD-07:** Approve numeric runtime, memory, design-size, and trace-navigation thresholds before benchmark measurement.
- **OD-08:** Confirm implementation language/build standard before prototype implementation.""")
s = s.replace(
"The following is the proposed default. It must be confirmed by the owner before Phase 1 (decision §18.2).",
"The owner approved this default on 2026-11-15 (Owner Decision OD-02).",
1
)
s = s.replace(
"C++17 is the provisional implementation language. It remains provisional until the Phase 0 prototype validates build, portability, and memory behavior (decision §18.8).",
"C++17 is a candidate implementation language; Owner Decision OD-08 must select the language/build standard before prototype implementation.",
1
)
# Fix body references to old subsection numbers where necessary.
s = s.replace("§14.1", "§15.1").replace("§14.2", "§15.2").replace("§14.3", "§15.3")
s = s.replace("§15.2.2", "§15.2.2")
# Correct historical heading numbers that may remain in the original copied text.
for old, new in [
    ("### 14.1 MVP RTL profile", "### 15.1 MVP RTL profile"),
    ("### 14.2 MVP SVA profile", "### 15.2 MVP SVA profile"),
    ("### 14.3 Conformance matrix", "### 15.3 Conformance matrix"),
    ("### 15.1 Phase 0 — Feasibility and semantic prototype", "### 16.1 Phase 0 — Feasibility and semantic prototype"),
    ("### 15.2 Phase 1 — MVP for block-level designs", "### 16.2 Phase 1 — MVP for block-level designs"),
    ("### 15.3 Phase 2 — Subsystem scalability", "### 16.3 Phase 2 — Subsystem scalability"),
    ("### 15.4 Phase 3 — Profile and proof expansion", "### 16.4 Phase 3 — Profile and proof expansion")
]:
    s = s.replace(old, new)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(s, encoding="utf-8", newline="\n")
print("Candidate:", out)
print("SHA-256:", hashlib.sha256(s.encode("utf-8")).hexdigest().upper())
print("Lines:", len(s.splitlines()))
