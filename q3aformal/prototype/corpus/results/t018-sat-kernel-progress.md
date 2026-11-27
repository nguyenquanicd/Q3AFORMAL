# T018 SAT Kernel Progress

## Windows memory policy, 2026-11-21

Bounded model checking (BMC) and k-induction now sample available physical memory and the private committed bytes of the Q3AFORMAL process. At startup, the automatic limit allows growth of up to half the available physical memory. During encoding and SAT search, sampling also protects a physical reserve of up to 512 MiB. A positive `Q3A_MEMORY_LIMIT_MIB` lowers the private memory limit. If a sample plus the estimated immediate allocation exceeds the budget, the command emits `UNKNOWN` with exit code 3 and a memory diagnostic.

`test_formal_memory_budget.ps1` verifies memory stops for BMC and induction at an explicit 1 MiB limit, invalid configuration rejection, absence of published induction evidence for the stopped run, and the normal replayed witness and checked proof with the default policy. `test_sat_cdcl.ps1` verifies that interrupting a temporary clause solve restores the base formula. Its 5,400 finite differential queries and 1,233 proof checks also pass. The bounded query and implication cover regressions pass on the rebuilt command.

The budget is sampled around model construction, during conjunctive normal form (CNF) encoding and SAT search, and before selected replay/proof boundaries. It is a cooperative limit. Proof checker allocation and bundle serialization can still grow between checks. Disk streaming and a measured peak-memory comparison for larger inputs remain open.

## Scope of this increment

The earlier increment added signed and unsigned relational comparison lowering to the expression-level T-IR bit-blaster for `<`, `<=`, `>`, and `>=`. Operand bits are compared from most significant to least significant. When both operands are signed, the sign bit is inverted before unsigned lexicographic comparison, mapping two's-complement order to unsigned order. Mixed-sign operands use unsigned comparison, consistent with the selected rule in the current typed expression representation. Operands must have equal widths; implicit sizing and conversion are rejected.

The expression encoder emits Tseitin CNF into the Q3A-owned DPLL solver. At that initial increment it did not encode a complete T-IR module, next-state relation, or SVA monitor. The equal-width restriction described here was later superseded for the tested mixed-width operator slice; see [expression width-extension progress](t016-expression-width-extension-progress.md).

## Test-first evidence

The new `prototype/tests/test_sat_relational_bitblast.ps1` compiles a standalone oracle against the SAT core and bit-blaster. The first run failed at the `<` expression with a source-located diagnostic because relational lowering was not implemented. After the initial implementation, the oracle passed every 2-bit pair for all four operators and all four combinations of operand signed declarations. For each valuation it checked that the expected predicate value was satisfiable and the opposite value was unsatisfiable. At that point a width mismatch was rejected. That check is now superseded by the mixed-width extension vectors documented below.

## Build and regression evidence

The initial C++17 Windows build completed with the repository warning flags, and the then-existing nine PowerShell regression scripts passed.

## Bounded transition-CNF increment

The next test-first step added `TransitionCnfEncoder` and the CLI command:

```powershell
q3aformal-sourcecheck --transition-cnf <project.q3a> --frames N
```

The first run of `test_transition_cnf_frames.ps1` failed because the command did not exist. The implementation now allocates independent signal bits for frames 0..N, constrains combinational equations in each frame, maps each next-state right-hand side at frame t to the target at t+1, and preserves simultaneous pre-edge reads. It leaves RTL state at frame 0 unconstrained and fixes generated `$past` validity-chain state to false at frame 0, per the approved model contract. DIMACS comments map `(frame, signal, bit)` to each variable. It rejects malformed model structure and unsupported clock/width/role cases instead of silently creating unconstrained signal references.

The expanded oracle confirms SAT for a valid shared-clock, two-register transition and synchronous reset; it confirms UNSAT when the second register incorrectly reads the new first-register value or reset fails to override an assignment. It also confirms that a handshake output cannot violate its combinational equation and that generated `$past` validity state cannot start true. After the change, the C++17 Windows build passed and all ten checked-in PowerShell regression scripts passed.

The `--transition-cnf` command emits a transition relation only. At this stage, no property query, counterexample replay, or proof artifact existed. The later scalar-query increment below adds a bounded property slice. These tests are focused implementation evidence, not general SAT soundness/completeness or RTL proof evidence. T018 remains open.

## Scalar bounded-property query increment

The new `test_bmc_property_queries.ps1` first failed because `--bmc` was not implemented. The CLI now accepts:

```powershell
q3aformal-sourcecheck --bmc <project.q3a> --property <assertion-name> --frames N
```

It compiles only one-term, one-bit scalar assertions and assumptions with no delay, repetition, or implication. Assumptions are applied at every eligible frame. A scalar `$past` reference reuses the generated history-state bit, and the property is suppressed until its T-IR history guard is active. The command tests assumption/model feasibility separately from the assertion violation query, reports `INCONSISTENT_MODEL_OR_ASSUMPTIONS` when the bounded base model is unsatisfiable, and reports whether the query was vacuous. SAT reports `BOUNDED_FAIL` plus a candidate frame; UNSAT reports `BOUNDED_PASS`, explicitly bounded rather than proven.

The oracle checks a tautological property (`BOUNDED_PASS`), an unconstrained input assertion (`BOUNDED_FAIL` with a candidate frame), a scalar environment assumption suppressing that failure, `$past` before and after its first valid sample, and fail-closed rejection of cover queries. The C++17 build and the regression scripts passed after this increment.

At the scalar-query milestone, the query evidence covered only scalar properties. Cover, trace decoding/replay, proof artifacts, and unbounded induction were still open. The later sequence increment below expands the query subset but does not establish general SAT solver correctness or complete SystemVerilog Assertion (SVA) support. T018 remains open.

## Bounded implication-sequence increment

The updated `test_bmc_property_queries.ps1` was first run against `p_overlapped_chain`; it failed closed because the scalar-only query compiler rejected the sequence. The query compiler now expands the reviewed linear T-IR automata over frames for overlapped (`|->`) and non-overlapped (`|=>`) implications. It supports constant delays and positive bounded consecutive repetition in antecedent and consequent sequences. Each complete antecedent match end creates an obligation. A consequent obligation is only queried when its entire maximum temporal horizon fits within the finite bound, avoiding a false failure caused by a truncated trace. Assumptions may use the same supported implication subset. Path expansion and predicate-frame evaluation have explicit safety caps.

The end-to-end vector check finds bounded failures for the reviewed overlap chain, non-overlap chain, and `a[*1:3] |=> b` cases. An additional fixture proves a no-failure bounded result when scalar environment assumptions force the consequent predicates. Cover queries remain rejected.

The independent `prototype/tests/sequence_bmc_bitblast_test.cpp` compares the CNF query against a separate trace evaluator for every finite valuation in three compact cases: 512 overlapped-chain assignments, 64 non-overlapped assignments, and 256 bounded-repetition assignments, for 832 valuations total. All agree. This is exhaustive evidence only for those finite vectors and does not establish complete SVA semantics, SAT solver soundness in general, or unbounded proof support. At this historical milestone, counterexample traces were not yet decoded or replay-validated; the subsequent replay increment below addresses the supported subset.

## Bounded trace decode and independent replay increment

The replay work began test-first by requiring the BMC CLI to emit a validated replay marker and per-frame trace for scalar and sequence counterexamples. The new checks failed before implementation. The implementation now decodes each SAT model into frame-indexed signal values and calls `prototype/source/replay/property_replay.cpp`, which independently evaluates the current expression subset, recomputes every combinational and next-state equation, checks scalar and supported implication assumptions, and confirms that the selected assertion fails at the candidate obligation. The CLI suppresses `BOUNDED_FAIL` if replay rejects the candidate. Output includes `Q3A_BMC_REPLAY VALIDATED`, the candidate frame, and `Q3A_BMC_TRACE_SIGNAL` rows.

The end-to-end regression exercises scalar, sequential-state, `$past`, `casez`, overlapped and non-overlapped implications, bounded repetition, implication assumptions, and incomplete boundary reporting. The standalone implication oracle continues to compare all 832 finite assignments against an independent trace evaluator. These results demonstrate only the tested bounded subset; replay does not cover the full approved source/SVA profile, prove unbounded properties, or produce VCD/FSDB. At this historical milestone, RTL-integrated proof artifacts, induction obligations, a complete independent proof-checker acceptance corpus, incremental solving, clause learning, and complete SAT conformance/performance evidence remained open. A later per-solve CDCL increment is recorded below; independent solver-correctness evidence remains open. A standalone CNF-level DRAT prototype is tracked separately in `prototype/corpus/results/t019-drat-artifact-progress.md`. T018 and T020 remain in progress.

## Bounded cover-search increment

The BMC regression was extended test-first to require a reachable scalar cover, a reachable linear sequence cover, an independently replayed witness, and a bounded-miss result that is explicitly not `UNREACHABLE`. The first focused run failed because the CLI only accepted assertions. `TransitionCnfEncoder::add_cover_hit` now builds scalar or linear-sequence cover goals over the finite frames under the supported assumptions. A found model is decoded and replayed against the transition equations, assumptions, and cover goal before the CLI reports `COVERED`. A finite miss reports `UNKNOWN` with `Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND`; solver exhaustion reports `UNKNOWN` with `INCONCLUSIVE`. The CLI also reports whether the maximum sequence horizon was boundary-limited.

Evidence includes a scalar input cover and the existing `req ##1 ack` cover sequence. The scalar and sequence witnesses both pass independent replay. A zero-transition search that cannot contain the two-sample sequence reports a bounded miss and does not claim unreachability. `test_sequence_bmc_bitblast.ps1` now compares the cover CNF against an independent trace evaluator for 4 scalar, 64 sequence, and 256 bounded-repetition assignments (324 total); all agree. `test_property_replay.ps1` accepts a valid assertion/cover trace and rejects altered combinational equations, violated assumptions, a candidate frame where the assertion holds, and a trace that misses the cover goal. At this historical milestone, cover implication properties remained unsupported; the later increment below adds a bounded subset. These finite vectors do not prove full SVA semantics or unbounded reachability. T018 and T020 remain open.

## Replay-validated VCD export increment

The BMC regression first required an optional VCD path for a validated failure witness and absence of a file when no witness exists; the old CLI rejected the extended invocation. `--vcd <output.vcd>` now writes a standard two-state VCD after assertion-counterexample or cover-witness replay succeeds. The file contains T-IR signals at discrete sample frames, using one nanosecond per frame. Clock event signals are abstracted by frame boundaries and omitted because the transition model does not assign a physical waveform to the clock input. The exporter refuses paths equivalent to the project manifest or RTL source files.

The focused regression checks required VCD sections, multi-frame timestamps, inclusion of RTL data signals, omission of the abstract clock, no file on a no-witness result, and preservation of an RTL file when an overwrite is attempted. This is a visualization of the bounded T-IR trace, not a timing simulation or FSDB export. After this increment the C++17 Windows build passed and all 13 checked-in PowerShell regression scripts passed. T018/T020 remain open.

The accumulated tests establish focused evidence for the implemented relational bit-blaster, bounded transition relation, scalar and linear-sequence assertion/cover queries, replay rejection checks, and VCD serialization only. They do not establish general SAT solver soundness/completeness or end-to-end RTL proof correctness. T018 and T020 remain in progress.

## Mixed-width expression sizing increment

The bit-blaster and independent replay now extend unequal-width operands to the maximum operand width for the tested arithmetic, relational, equality, and bitwise operators. Sign extension is used only when both operands are signed; other combinations use zero extension. Conditional branches follow the same rule. The focused oracle checks all 3-bit/2-bit value pairs, all signedness combinations, and relational/equality/bitwise operators; conditional branch values and signedness combinations are also checked. `test_bmc_mixed_width.ps1` adds six source-level SAT/replay properties against explicitly extended references. See [T016/T017 expression width-extension progress](t016-expression-width-extension-progress.md) for scope and limits. This remains a narrow expression slice, not full SystemVerilog sizing conformance. T016, T017, and T018 remain open.

## Linear implication cover increment

`TransitionCnfEncoder::add_cover_hit` and independent witness replay now support linear implication covers using overlapped (`|->`) and non-overlapped (`|=>`) timing. A `COVERED` witness must contain at least one in-bound antecedent match and a complete in-bound consequent match; a vacuous implication is not treated as a useful bounded reachability witness. Incomplete consequent horizons remain `UNKNOWN` with a boundary-limited result.

`test_bmc_cover_implication.ps1` checks RTL-level overlapped, non-overlapped, and sequence-antecedent covers, plus an incomplete-bound miss. `test_sequence_bmc_bitblast.ps1` compares the SAT cover encoding with a separate trace evaluator over 64 overlapped and 512 non-overlapped valuations, in addition to the existing scalar/sequence cases, for 900 cover valuations total. `test_property_replay.ps1` accepts matching implication covers and rejects antecedent-only, vacuous, and wrong-candidate traces.

This bounded reachability interface does not implement IEEE property-coverage counters for both ordinary and vacuous successes. IEEE 1800-2017 §16.14.3 requires coverage results to distinguish successful and vacuous-success counts ([standard text](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf)); that accounting, full property attempt semantics, and unbounded reachability remain open. T018 and T020 remain in progress.

## Per-solve CDCL implementation increment

The production query kernel now performs 1-UIP conflict analysis, learns an asserting clause, and backjumps to the highest decision level represented by the remaining learned literals. Learned clauses are attached to the local two-watched-literal database and discarded with the per-call solver state. The variable activity score is bumped during conflict analysis and is used as a deterministic tie-breaker; decisions remain positive-first. SAT and BMC statistics now report learned-clause, total-backjump, and nonchronological-backjump counts. A crafted three-decision-level SAT formula asserts that the implementation skips an irrelevant middle level during backjumping.

The focused differential oracle in `prototype/tests/test_sat_cdcl.ps1` passed. It compares 1,800 deterministic random CNFs across three assumption sets each (5,400 queries: 1,682 SAT and 3,718 UNSAT) against exhaustive assignment enumeration for up to eight variables, and validates each returned SAT model against the original clauses and assumptions. It also checks a crafted 1-UIP conflict, a 4-pigeon/3-hole UNSAT formula by enumerating all 4,096 assignments, and decision/propagation resource-limit behavior. `test_bmc_property_queries.ps1`, `test_sequence_bmc_bitblast.ps1`, and `test_inductive_proof.ps1` also passed with the CDCL kernel.

These vectors provide focused differential evidence, not a general soundness proof or broad SAT conformance/performance evidence. Root assumptions and clauses learned under them are scoped to one `solve()` call. Incremental solving, restarts, learned-clause reduction, larger CNF stress, and broad solver conformance/performance evidence remain open. T018 and T020 remain in progress.

## CDCL proof-log integration increment

The SAT API now optionally records each learned clause and the final empty clause as a RUP proof log for assumption-free UNSAT queries. Proof recording fails closed if temporary assumptions are supplied; they must be encoded as unit clauses in the exact CNF. The scalar `--prove-inductive` path enables proof recording during its CDCL query and passes the log through the existing schema-2 artifact writer and structurally separate DRAT checker. The standalone proof-check CLI retains its independent bounded DPLL proof generator. Bounded `--bmc` queries still do not emit proof artifacts.

The independent checker accepted the crafted UNSAT and pigeonhole CDCL proofs plus 1,233 random UNSAT proof logs; assumptions were encoded as CNF units. `test_inductive_proof.ps1` then passed for k=1 and k=2 obligations, and rechecked both base and step artifacts with the standalone checker. An incomplete or missing CDCL log returns `UNKNOWN`, never `PROVEN`. This does not prove the SAT producer correct in general or validate source-to-T-IR translation; those remain in the trusted base and open evidence gaps.

## 2026-11-19 delayed `$past` implication alignment

The bounded assertion, assumption, cover, induction, and witness-replay paths now consume T-IR 0.4's separate antecedent and consequent history guards at their respective sequence starts. The lowerer computes the warm-up needed at a sequence start from each history-using term's earliest sample offset. This fixes delayed antecedent and consequent checks where a property-wide guard at antecedent start suppressed an otherwise valid obligation. `test_sva_delayed_past_implication.ps1`, `test_bmc_property_queries.ps1`, `test_bmc_cover_implication.ps1`, and `test_inductive_sva_implication.ps1` passed, including independently replayed assertion, cover, and induction counterexample traces.

This does not close full-profile SVA semantics or RTL-to-T-IR translation. Those remain open under T016/T017/T020; broader SAT soundness, conformance, and performance evidence also remains open under T018.
