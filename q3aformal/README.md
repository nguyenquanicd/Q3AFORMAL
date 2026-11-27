# Q3AFormal Spec Kit Workspace

This workspace holds the product specification, the Phase 0 feasibility plan, owner decisions, and the source/model conformance corpus.

## Current product baseline

The canonical product specification is [Q3AFORMAL_SPECIFICATION.md](../Q3AFORMAL_SPECIFICATION.md), revision 0.10. The approved revision 0.9 baseline is preserved at [Q3AFORMAL_SPECIFICATION_v0.9.md](specs/002-phase0-feasibility/proposed/Q3AFORMAL_SPECIFICATION_v0.9.md); revision 0.8 remains preserved as the original hash-identified input under specs/002-phase0-feasibility/inputs/.

## Accepted Windows x64 release

All four roadmap phases and 20 acceptance criteria are closed for the owner-approved revision 16 scope. The package passed 119 regression suites, the Phase 0 and Phase 1 compatibility cases, and all 15 Phase 2 subsystem measurements. The revision 16 package digest identifies the exact executable pair under review. [Download revision 16](dist/q3aformal-windows-x64-development-preview-r16.zip) · [Release acceptance](evidence/r16/release-acceptance.json) · [User guide](USER_GUIDE.md)

## Phase history

**Phase 0 is closed.** The owner approved Gate B GO on 2026-11-24 with C++17 and Deletion Resolution Asymmetric Tautology (DRAT). All 33 tasks are complete. The accepted Windows build passed 68 regression suites, eight benchmark cases, and four bundle revalidations for the approved profile. The exact build and scope are recorded in the [Gate B decision package](evidence/phase0-go-no-go.md).

**Phase 1 Windows x64 candidate passed technical qualification.** The product command accepts version 1 and version 2 project manifests and emits a versioned machine-readable result. Property Directed Reachability (PDR) checks assertions and cover goals under assumptions with finite delays and positive repetition ranges. It emits three independently checkable DRAT refutations for each accepted invariant. [Phase 1 plan](specs/003-phase1-block-mvp/plan.md) · [Temporal assumption example](prototype/pdr-temporal-assumptions.q3a)

The historical Phase 1 Windows x64 candidate included the native workbench and Windows proof-cache path fixes. It passed the eight Phase 0 compatibility cases, four source-backed bundle checks, all five approved Phase 1 block cases, and all six visible OD-07 GUI runs. All 118 regression suites passed. The release audit associates the 18 applicable Phase 1 criteria with the exact package. [Regression summary](evidence/r-dlg/summary.json) · [Release evidence audit](evidence/release/native-dialog-integrated-2026-11-26/release-evidence-audit.json). [Current Windows candidate](dist/q3aformal-phase1-windows-x64-native-dialog-candidate.zip) · [GUI verdict](evidence/r-gui-od07/verdict.json) · [Phase 1 acceptance ledger](specs/003-phase1-block-mvp/release-acceptance.md)

**Phase 2 staging.** The Windows candidate supports serial checkpoint recovery and optional parallel proof workers with Windows-enforced memory limits. The integration test reproduces serial outcomes, revalidates resumed proofs, and exercises cancellation and a queued worker's rejection of changed sources. This work was staged against the qualified Phase 1 package. [Batch design](specs/004-phase2-subsystem/batch-scheduling-resume-review.md) · [Parallel qualification](evidence/r-p2-workers/qualification.json)

The same Phase 2 workstream now includes source-derived proof composition for one-clock, same-sample safety guarantees. The Windows test matched a whole-model proof, independently checked eight obligations, and replayed a concrete counterexample from changed wiring. [Composition design](specs/004-phase2-subsystem/proof-composition-review.md) · [Composition qualification](evidence/r-p2-composition-qualified/all-standalone-proofs.json)

Native equivalence is staged for one-clock designs with an explicit port map. The Windows candidate checked independent initial states and both polarities of first-edge reset. It replayed a real output difference caused by an additional register stage. [Equivalence contract](specs/004-phase2-subsystem/memory-and-equivalence-review.md#q3aformal-equivalence-plan) · [Windows qualification](evidence/r-p2-equivalence/qualification.json)

Equivalence plans can also declare an equal or inverted state correspondence. The separate proof distinguishes first-sample failures from later preservation failures, and output verification remains a separate obligation. [State correspondence](specs/004-phase2-subsystem/memory-and-equivalence-review.md#declared-state-correspondence) · [Windows proof checks](evidence/r-p2-state-relation/standalone-all.json). The explicit `initial matched` scope restricts pairs only at sample zero and verifies that the declared relation remains true afterward. [Matched-start qualification](evidence/r-p2-matched-initial/qualification.json)

The opt-in multi-clock build opens source-verified event witnesses in the native Windows viewer. The cursor shows the global step and each clock's local sample or idle state. The development build passed 36 CLI checks and six standalone DRAT obligations. The standard build passed its native debug regression and subsystem functional preflight. [Multi-clock viewer commands](specs/004-phase2-subsystem/multi-clock-scheduling-review.md#native-windows-event-trace-viewer) · [Windows qualification](evidence/p2-event-gui-development/qualification.json)

The Phase 2 exact-memory source build also admits registered and combinational scalar control on the memory clock. It proved history-dependent read-back and read hold, reopened the original array certificate, and passed the existing development suites. [Memory profile and constraints](specs/004-phase2-subsystem/memory-and-equivalence-review.md#same-clock-scalar-controls) · [Windows qualification](evidence/p2-memory-scalar-integration/qualification.json)

**Phase 3 staging.** Batch plan version 3 supports explicitly listed parameter configurations. Its serial and parallel checks keep each configuration's proof evidence and reject checkpoint reuse across effective parameter values. [Parameter sweep contract](specs/005-phase3-profile-expansion/parameter-sweep.md) · [Windows qualification](evidence/r-p3-sweep/qualification.json)

[Phase 3 release readiness](specs/005-phase3-profile-expansion/release-readiness.md) records acceptance evidence and outstanding items for the expanded profiles, protocol applications, and replay.

The Phase 3 liveness development command checks eventual response on explicit graphs derived from supported SystemVerilog projects. The development profile supports named assertions with overlapped or nonoverlapped strong eventually. It detects fair infinite counterexamples and distinguishes an infeasible fairness environment from an admissible model without a violation. [Scope and commands](specs/005-phase3-profile-expansion/fair-cycle-liveness.md) · [Source, archive and named SVA qualification](evidence/p3-live-sva/qualification.json) · [Verified loop waveform qualification](evidence/p3-live-vcd/qa/qualification.json)

The Phase 3 four-state expression component covers packed 0, 1, X, and Z evaluation and selected SAT encodings. The opt-in Windows evaluator now accepts a flat continuous-assignment SystemVerilog project and reports both model identity and concrete signal values. The combinational proof path checks exact output claims for all four-state inputs, verifies DRAT certificates, and independently replays counterexamples. The sampled sequential path checks a single requested sample from an X-initialized state, with independent certificate checking and counterexample replay. The same profile checks named assertions with finite fixed or ranged delays, consecutive repetitions, and overlapped or nonoverlapped implications through a bound. Completed environment assumptions constrain its searches, with separate infeasibility and provisional witness results. The bounded profile supports `$past`, `$stable`, `$changed`, `$rose`, and `$fell` on sampled packed signals and constant selects. Its history retains X and Z and starts at X before the first sample. Finite cover goals return persistent witnesses that can be replayed from source, or a checked certificate for absence within the selected bound. Replayed matches and counterexamples can be exported to a Value Change Dump (VCD) waveform that preserves X and Z. [Four-state qualification](specs/005-phase3-profile-expansion/four-state-expressions.md)

A separate Phase 3 development executable supports guarded sampled-value functions in SystemVerilog Assertions. Six safety proofs verify against the original source and run configuration, including nested history. A cover hit and a counterexample also replay from source. [Sampled-value profile](specs/005-phase3-profile-expansion/sampled-value-profile.md) · [Windows qualification](evidence/p3-sampled-dev/conformance-retry/qualification.json)

The current Phase 3 source build also checks one-hot vectors and counts set bits in assertions. Eight checked safety proofs cover all 32 five-bit input values, scalar and 64-bit boundaries, signed arithmetic, and startup history validity. [Bit-vector qualification](evidence/p23-vector-build/qualification.json)

Equivalence failures now export paired Value Change Dump (VCD) waveforms with shared inputs and a sample marker. Reopening checks the waveform against source-replayed values. [Waveform qualification](evidence/r-paired-wave/qualification.json)

The Phase 2 and Phase 3 Windows x64 preview packages the latest staged features in a separate ZIP. The extracted build passed all 118 product regression suites and eight focused suites, including proof composition, equivalence, parameter sweep and paired waveforms. It reproduced all eight Phase 0 cases and four source-backed bundle revalidations. It also passed the five Phase 1 block benchmarks and six native graphical user interface (GUI) runs within their approved limits. The Phase 2 subsystem workloads passed functional checks. The timed acceptance for this historical preview was completed on revision 16. [Preview package](dist/q3aformal-windows-x64-phase23-preview.zip) | [Build and test evidence](evidence/release/phase23-preview/qualification.json)

**Windows development preview.** A separately labeled ZIP includes the exact-memory, free-event-mask, and guarded sampled-value profiles. The extracted executable passed all three focused profile suites, the native event-viewer session check, and Phase 2 subsystem functional preflight. Packaging validates the development channel against the running build identity. [Download Windows x64 preview](dist/q3aformal-windows-x64-development-preview.zip) · [Preview commands](docs/windows-development-preview.md) · [Integrated qualification](evidence/p23-integrated-qualification/qualification.json)

**Windows development preview revision 2.** This archive adds bit-vector functions and retains each population-count operand once in the model. The same triple-nested 64-bit input generates a 2,892-byte model where the expanded build generated 101,192,302 bytes. The extracted archive passed the integrated suite with 14 sampled and bit-vector proofs and 19 independently checked obligations. Across three Windows development runs per build, the median peak working set for this lowering case fell from 437.04 to 10.84 MiB. The explicit memory-limit regression also passed on the extracted executable. [Process memory](evidence/p23-compact-archive-qualification/process-memory-comparison.json) · [Memory-limit regression](evidence/p23-compact-archive-qualification/memory-budget-regression.txt) [Download revision 2](dist/q3aformal-windows-x64-development-preview-r2.zip) · [Qualification](evidence/p23-compact-archive-qualification/qualification.json) · [Model size comparison](evidence/p23-compact-archive-qualification/model-size-comparison.json)

**Phase 3 protocol application.** The 32-bit AXI4-Lite write fixture checks independent address and data, byte strobes, response ordering and backpressure against an independent transaction scoreboard. The extracted revision 2 build produced ten source-revalidated proofs, six replayed cover goals and three replayed injected-fault counterexamples. [Protocol scope and commands](specs/005-phase3-profile-expansion/axi-lite-write-application.md) · [Windows qualification](evidence/p3-axi-lite-write/qualification.json)

The complementary 32-bit read fixture checks mapped and unmapped responses, captured read data, and backpressure for one outstanding request. Preview r3 passed ten source-revalidated proofs, four replayed covers, and three replayed injected-fault counterexamples. [Read protocol scope and commands](specs/005-phase3-profile-expansion/axi-lite-read-application.md) · [Windows qualification](evidence/p3-axi-read/qualification.json)

**Windows development preview revision 7.** The four-state profile includes variable bit and indexed part-select reads plus persistent counterexample replay. The extracted pair passed 24 profile suites, eight Phase 0 cases with four revalidated bundles, five Phase 1 block workloads, and six approved native GUI runs. All 118 repository suites passed across the original run and a targeted proof-cache retry after freeing Windows disk space. [Download revision 7](dist/q3aformal-windows-x64-development-preview-r7.zip) · [Qualification](evidence/r7/qualification.json)

**Windows development preview revision 8.** The extracted build adds finite sequence `and`, `intersect`, and `or` plus sample-window pruning for repeated paths. It passed all 118 repository suites, 28 integrated profile suites, eight Phase 0 cases with four source-revalidated bundles, five approved Phase 1 block workloads, and six approved native GUI runs. [Download revision 8](dist/q3aformal-windows-x64-development-preview-r8.zip) · [Qualification](evidence/r8/qualification.json)

**Windows development preview revision 9.** The extracted build adds finite sequence `throughout` and `within` and packed integral multiplication in the four-state profile. It passed 118 repository suites, 31 integrated profile suites, eight Phase 0 cases with four source-revalidated bundles, five approved Phase 1 block workloads, and six approved native GUI runs. [Download revision 9](dist/q3aformal-windows-x64-development-preview-r9.zip) · [Qualification](evidence/r9/qualification.json)

**Windows development preview revision 10.** The extracted build adds model export, wildcard equality, and procedural `casex`. It passed 118 repository suites, 34 integrated profile suites, six application suites, and the approved Phase 0 and Phase 1 compatibility runs. The four-state audit matched 374 reports to regenerated models and checked five temporal composition forms. [Download revision 10](dist/q3aformal-windows-x64-development-preview-r10.zip) · [Qualification](evidence/r10/qualification.json) · [Four-state conformance matrix](specs/005-phase3-profile-expansion/conformance-matrix.md)

**Windows development preview revision 11.** The extracted build adds packed division and remainder and module-local, parameterless named sequences. It passed 36 integrated profile suites, six application suites, 410 source-to-model identity checks, and all Phase 0 and Phase 1 compatibility runs, including the six OD-07 measurements. The repository regression passed 117 of 118 suites. On this host, the proof-cache copy test reproduced a truncated certificate under low disk space. [Download revision 11](dist/q3aformal-windows-x64-development-preview-r11.zip) · [Qualification](evidence/r11/qualification.json) · [OD-07 verdict](evidence/r11/gui/verdict.json) · [Copy diagnostic](evidence/r11/cache-copy-diagnostic/scratch-hashes.json)

**Windows development preview revision 12.** The four-state profile adds finite `first_match`. Proof-cache publication verifies copied certificate bytes before making the file visible. The extracted package passed 118 repository regressions, 37 profile suites, six application suites, eight Phase 0 cases, four source-backed bundle checks, five approved Phase 1 block benchmarks and all six approved GUI runs. The source-to-model audit matched 427 reports and checked the first-match history guard. [Download revision 12](dist/q3aformal-windows-x64-development-preview-r12.zip) · [Qualification](evidence/r12/qualification.json) · [Source-to-model audit](evidence/r12/four-state-conformance.json)

**Windows development preview revision 13.** The four-state profile adds reusable named properties with a single explicit sampling clock. The extracted package passed 38 profile suites, six application suites and the approved Phase 0 and Phase 1 compatibility runs. The audit matched 437 source-to-model reports. All 118 repository suites passed across the original run and a targeted retry after the host memory limit interrupted the 300-transition cover regression. [Download revision 13](dist/q3aformal-windows-x64-development-preview-r13.zip) · [Qualification](evidence/r13/qualification.json) · [Source-to-model audit](evidence/r13/four-state-conformance.json)

**Windows development preview revision 14.** The SAT solver keeps two watched positions per clause and reads literals from the original clause arena. The 300-transition cover reached and replayed its witness with a 192 MiB private-memory limit. Sampled peak private commit fell by 14.76% at the common 256 MiB limit. The model, SAT formula and indexed witness matched across builds. The package passed all 118 repository suites on its first run, 38 profile suites, six application suites and the approved Phase 0 and Phase 1 compatibility runs. [Download revision 14](dist/q3aformal-windows-x64-development-preview-r14.zip) · [Qualification](evidence/r14/qualification.json) · [Memory evidence](evidence/p3-compact-sat-watch/qualification.json)

**Windows development preview revision 16.** The Windows launcher converts native UTF-16 arguments to UTF-8 for the command-line tool and the standalone proof checker. The extracted archive passed its runtime audit and eight clean-installation checks from paths containing spaces and Vietnamese characters. The package passed compatibility qualification across 119 suites, including the Unicode regression. An isolated retry passed the one suite interrupted by the host physical-memory reserve on the first run. [Compatibility qualification](evidence/r16/qualification.json) [Revision 16 archive](dist/q3aformal-windows-x64-development-preview-r16.zip) · [Clean-installation evidence](evidence/r16/portable-install-qualification.json)

**Windows development preview revision 15.** Before its first conflict, the SAT solver continues decision selection from the lowest variable that can still be unassigned. The extracted package passed all 118 repository suites, 38 profile suites, six application suites, six focused Phase 2 suites and all approved Phase 0 and Phase 1 compatibility runs. The source-to-model audit matched 437 reports. [Download revision 15](dist/q3aformal-windows-x64-development-preview-r15.zip) · [Qualification](evidence/r15/qualification.json) · [Solver comparison](evidence/p3-sat-decision-cursor/qualification.json)

**Windows development preview revision 6.** The integrated four-state profile adds hierarchical SystemVerilog designs, procedural `case` and `casez`, arithmetic, reductions, and variable shifts. The extracted pair passed all 118 repository regressions and 21 profile suites, plus eight Phase 0 cases with four revalidated bundles, five Phase 1 block workloads, and six approved native GUI runs. [Download revision 6](dist/q3aformal-windows-x64-development-preview-r6.zip) · [Qualification](evidence/r6/qualification.json)

**Windows development preview revision 5.** The extracted package adds the four-state RTL and finite SVA profile with a runnable SystemVerilog example. It passed all 118 repository regressions and 16 profile suites, including nine four-state suites, plus eight Phase 0 cases with four revalidated source bundles, five Phase 1 block workloads, and six approved native GUI runs. [Download revision 5](dist/q3aformal-windows-x64-development-preview-r5.zip) · [Qualification](evidence/r5/qualification.json)

**Windows development preview revision 4.** The integrated package includes strong eventual-response SystemVerilog Assertions, source-verified liveness archives and loop waveforms, plus exact-memory activation and range diagnostics. The extracted binary pair passed 118 repository regressions, 14 focused suites, eight Phase 0 cases, four source-backed bundle checks, five Phase 1 block workloads and six native GUI runs. Phase 2 timing was subsequently accepted on revision 16. [Download revision 4](dist/q3aformal-windows-x64-development-preview-r4.zip) · [Qualification](evidence/r4/qualification.json) · [Phase 2 readiness](specs/004-phase2-subsystem/release-readiness.md)

### Earlier candidate evidence

The macro-unit Windows x64 candidate accepts definitions-only and include-only SystemVerilog files in version 2 projects. Four proof and witness bundles reopened from source. The package passed eight Phase 0 cases, four source-required bundle checks and the five approved native Phase 1 cases. This was an earlier macro compilation-unit qualification. [Windows macro-unit candidate](dist/q3aformal-phase1-windows-x64-macro-units-candidate.zip) · [Macro qualification](evidence/release/macro-compilation-unit-product-staged-2026-11-25/product-qualification/qualification.json) · [Native verdict](evidence/benchmark/runs/phase1-macro-unit-approved-native-2026-11-25/approved-limit-verdict.json)

The PDR provenance Windows x64 candidate preserves checked certificate identities and the originating run configuration. Its reader compares the saved settings and ordered source roster with the project used for verification. The extracted package passed its runtime audit. The focused staged checks rejected eight substitutions and reopened historical certificates. The package passed eight Phase 0 cases, four source-required bundle checks and five Phase 1 native cases under the approved limits. An independent checker accepted all three PDR obligations. An observed 651-file batch stopped before scheduling in 29 ms after cancellation. [Native workload results](evidence/benchmark/runs/phase1-pdr-source-context-approved-native-2026-11-25/approved-limit-verdict.json) · [Batch cancellation evidence](evidence/release/batch-source-loading-2026-11-25/packaged-v2-context-qualification.json) · [Nine focused suites](evidence/release/pdr-source-context-targeted-2026-11-25/summary.json) [Windows PDR provenance candidate](dist/q3aformal-phase1-windows-x64-pdr-provenance-candidate.zip) · [Certificate context qualification](evidence/release/pdr-certificate-context-staged-2026-11-25/qualification.json)

The source-control Windows x64 candidate polls cancellation and deadlines while loading a single-project proof. It passed eight Phase 0 compatibility cases, four source-required bundle checks and five Phase 1 native cases at the approved limits. Its 651-file trial stopped at 252–269 ms against 250 ms deadlines. All eight targeted suites passed, including the earlier memory-limited history oracle. The full sweep passed 110 of 112 suites. The CLI expectation for early cancellation was corrected and passed on rerun. The range oracle timed out in the original sweep. [Full sweep](evidence/release/source-control-full-regression-2026-11-25/summary.json) [Focused regression](evidence/release/source-control-targeted-2026-11-25/summary.json) [Windows source-control candidate](dist/q3aformal-phase1-windows-x64-source-control-candidate.zip) · [Source-load interruption cases](evidence/release/source-loading-deadline-2026-11-25/console-ready-large-project/qualification.json) · [Approved native benchmark](evidence/benchmark/runs/phase1-source-control-approved-native-2026-11-25/approved-limit-verdict.json)

The interruption-configuration Windows x64 candidate records the resolved configuration when BMC, k-induction or PDR is interrupted. It passed all 110 regression suites, eight Phase 0 compatibility cases, four source-required Phase 0 bundle checks and five Phase 1 native cases at the approved limits. The standalone checker accepted all three PDR proof obligations from the native arbiter case. Eight contradiction archives from this package reopen from source. [Windows candidate](dist/q3aformal-phase1-windows-x64-interruption-config-candidate.zip) · [Windows quick start](docs/windows-package.md) · [Full regression](evidence/release/interruption-config-full-regression-2026-11-25/summary.json) · [Interruption records](evidence/release/interruption-config-full-regression-2026-11-25/test_product_run_control.json) · [Approved native benchmark](evidence/benchmark/runs/phase1-interruption-config-approved-native-2026-11-25/approved-limit-verdict.json) · [Standalone DRAT checks](evidence/benchmark/runs/phase1-interruption-config-approved-native-2026-11-25/standalone-drat-verdicts.json) · [Acceptance ledger](specs/003-phase1-block-mvp/release-acceptance.md)

## Phase 0 artifacts

- [User Guide: Windows build, inputs, commands, options, and outputs](USER_GUIDE.md)
- [Feature specification](specs/002-phase0-feasibility/spec.md)
- [Implementation plan](specs/002-phase0-feasibility/plan.md)
- [Research and alternatives](specs/002-phase0-feasibility/research.md)
- [Task list](specs/002-phase0-feasibility/tasks.md)
- [Specification refinement disposition](specs/002-phase0-feasibility/proposed/SPECIFICATION_REFINEMENT_PROPOSAL.md)
- [Owner decision register](docs/phase0/decision-register.md)
- [Benchmark plan](docs/phase0/benchmark-plan.md)
- [Proposed Phase 0 time and memory thresholds](docs/phase0/benchmark-threshold-proposal.md)
- [Phase 0 benchmark runner and job schema](prototype/benchmark/README.md)
- [Benchmark runner memory-profile regression](prototype/tests/test_benchmark_runner_memory_profile.ps1)
- [Proof-evidence plan](docs/phase0/proof-evidence-plan.md)
- [Requirement-to-phase-to-acceptance traceability matrix](docs/phase0/requirements-traceability.csv)
- [Phase 0 Gate B decision and acceptance evidence](evidence/phase0-go-no-go.md)
- [Canonical model contract](docs/phase0/model-contract.md)
- [Versioned conformance corpus](prototype/corpus/README.md)
- [Conformance matrix](prototype/corpus/conformance-matrix.csv)
- [T008 source-to-model coverage map](prototype/corpus/source-model-vectors/coverage-map.md)
- [Source manager interface and build instructions](prototype/source/source_manager/README.md)
- [Frontend lexer status](prototype/source/frontend/README.md)
- [T015 elaborator progress evidence](prototype/corpus/results/t015-elaborator-progress.md)
- [T013 source manager implementation evidence](prototype/corpus/results/t013-source-manager.md)
- [T014 parser implementation evidence](prototype/corpus/results/t014-parser.md)
- [T018 SAT kernel progress evidence](prototype/corpus/results/t018-sat-kernel-progress.md)
- [T019 DRAT artifact/checker progress evidence](prototype/corpus/results/t019-drat-artifact-progress.md)
- [Phase 0 benchmark and approved limits](evidence/benchmark/benchmark-report.md)
- [T029 benchmark runner and host profile](prototype/corpus/results/t029-runner-progress.md)
- [B-01..B-05 functional preflight index and source hashes](evidence/benchmark/preflight/README.md)
- [Independent full-scan RUP regression](prototype/tests/test_drat_independent_full_scan.ps1)
- [RTL-015 concatenation conformance evidence](evidence/conformance/rtl-015-concat-three-2026-11-19.md)
- [RTL-007 fill-literal conformance evidence](evidence/conformance/rtl-007-fill-literals-2026-11-19.md)
- [RTL-007 fill-literal regression](prototype/tests/test_fill_literal_context.ps1)
- [RTL-005 unsized-decimal assignment-sizing evidence](evidence/conformance/rtl-005-decimal-context-2026-11-19.md)
- [RTL-005 assignment-sizing regression](prototype/tests/test_unsized_decimal_context.ps1)
- [RTL-005 mixed signal/decimal context evidence](evidence/conformance/rtl-005-mixed-decimal-context-2026-11-19.md)
- [RTL-005 mixed-context regression](prototype/tests/test_unsized_decimal_mixed_context.ps1)
- [T017 RTL-001 missing-top diagnostic evidence](prototype/corpus/results/t017-rtl001-missing-top-diagnostic.md)
- [T017 RTL-002 hierarchy-port diagnostics](prototype/corpus/results/t017-rtl002-hierarchy-port-diagnostics.md)
- [RTL-003 parameter and model identity regression](prototype/tests/test_parameter_identity_conformance.ps1)
- [RTL-004 packed type boundary regression](prototype/tests/test_packed_type_boundaries.ps1)
- [RTL-019 continuous-driver diagnostic evidence](prototype/corpus/results/rtl-019-continuous-driver-diagnostics-2026-11-19.md)
- [RTL-019 continuous-driver regression](prototype/tests/test_continuous_driver_diagnostics.ps1)
- [RTL-017 constant-shift boundary evidence](prototype/corpus/results/rtl-017-shift-boundaries-2026-11-19.md)
- [RTL-017 arithmetic-right-shift extension evidence](prototype/corpus/results/t017-rtl017-arithmetic-right-shift-extension-2026-11-20.md)
- [Phase 0 arithmetic right shift rejection regression](prototype/tests/test_bmc_rtl_017_arithmetic_right_shift.ps1)
- [RTL-017 profile amendment candidate](specs/002-phase0-feasibility/reports/RTL017_ARITHMETIC_SHIFT_PROFILE_AMENDMENT.md)
- [RTL-017 source-level shift regression](prototype/tests/test_bmc_rtl_017_shifts.ps1)
- [RTL-017 unsupported-distance regression](prototype/tests/test_bmc_rtl_017_unsupported_shifts.ps1)
- [T-IR 0.4 SVA history-guard alignment evidence](prototype/corpus/results/t016-sva-history-guard-alignment-2026-11-19.md)
- [T017 SVA implication/repetition boundary evidence](prototype/corpus/results/t017-sva-alignment-boundaries-2026-11-19.md)
- [T017 SVA `$past` reset-crossing evidence](prototype/corpus/results/t017-sva-past-reset-evidence-2026-11-19.md)
- [SVA sequence-alignment oracle](prototype/tests/test_sva_sequence_alignment_oracle.ps1)
- [SVA `$past` history/frame oracle](prototype/tests/test_sva_history_frame_oracle.ps1)
- [Delayed `$past` implication regression](prototype/tests/test_sva_delayed_past_implication.ps1)
- [T024–T026 result-bundle implementation evidence](prototype/corpus/results/t024-t026-result-bundles.md)
- [CNF proof artifact prototype and limits](prototype/checker/README.md)
- [Versioned run bundle format and limits](prototype/source/bundle/README.md)
- [Checker corpus verdicts and fingerprints](evidence/checker-corpus/verdicts.md)
- [T019 exhaustive DRAT SAT-preservation evidence](evidence/checker-corpus/drat-sat-preservation-2026-11-19.md)
- [T019 three-variable DRAT SAT-preservation sample](evidence/checker-corpus/drat-three-variable-sat-preservation-2026-11-19.md)
- [T019 independent three-variable RUP/RAT differential](evidence/checker-corpus/drat-rat-differential-2026-11-20.md)
- [T019 checker resource limits and Windows CRLF evidence](evidence/checker-corpus/drat-resource-limits-and-crlf-2026-11-19.md)
- [T019 watched-literal RUP relocation cross-check](evidence/checker-corpus/drat-watched-rup-relocation-2026-11-19.md)
- [T019 DRAT clause-normalization edge evidence](evidence/checker-corpus/drat-clause-normalization-2026-11-20.md)
- [T020 frame-by-frame replay mutation evidence](prototype/corpus/results/t020-replay-single-bit-mutation-2026-11-20.md)
- [T017 RTL-020 process-control conformance evidence](prototype/corpus/results/t017-rtl020-process-control-2026-11-20.md)
- [T017 RTL-025 priority-if conformance evidence](prototype/corpus/results/t017-rtl025-priority-if-else-2026-11-20.md)
- [T017 RTL-026 exact-case conformance evidence](prototype/corpus/results/t017-rtl026-case-order-2026-11-20.md)
- [T017 RTL-029 static generate-for conformance evidence](prototype/corpus/results/t017-rtl029-generate-for-conformance-2026-11-20.md)
- [T017 RTL-016 packed-select conformance evidence](prototype/corpus/results/t017-rtl016-packed-select-conformance-2026-11-20.md)
- [T017 RTL-010 unary-operator conformance evidence](prototype/corpus/results/t017-rtl010-unary-conformance-2026-11-20.md)
- [T017 RTL-011–RTL-014 mixed-width conformance evidence](prototype/corpus/results/t017-rtl011-014-mixed-width-conformance-2026-11-20.md)
- [T017 SVA-004 bounded-cover conformance evidence](prototype/corpus/results/t017-sva004-bounded-cover-conformance-2026-11-20.md)
- [RTL-019 bounded driver-ownership evidence](prototype/corpus/results/rtl-019-continuous-driver-diagnostics-2026-11-19.md)
- [Known-pass scalar induction evidence](evidence/known-pass/README.md)
- [Guarded `$past` induction artifacts and countermodel](evidence/induction-guarded-past/README.md)
- [Known-fail replayed witness evidence](evidence/known-fail/README.md)
- [Phase 0 positive syntax manifest](prototype/supported-parse.q3a)
- [Cross-artifact analysis report](specs/002-phase0-feasibility/reports/SPECIFICATION_ANALYSIS_REPORT.md)

## Historical review

- [Revision 0.8 single-document analysis](specs/001-q3aformal-spec-analysis/SPECIFICATION_ANALYSIS_REPORT.md)
- [Requirements-quality checklist](specs/001-q3aformal-spec-analysis/checklists/requirements.md)
- [Original review plan](specs/001-q3aformal-spec-analysis/plan.md)
- [Original input snapshot](specs/001-q3aformal-spec-analysis/inputs/Q3AFORMAL_SPECIFICATION.md)

The Spec Kit analyze workflow is read-only with respect to its input spec/plan/tasks. Update those artifacts intentionally, then rerun analysis to refresh the report.

## Latest implementation update

RTL-019 is Supported for the bounded top-level ownership profile: exact-width equations lower, legal 8-to-4 assignment-context truncation is explicit in T-IR and passes BMC, and duplicate whole-signal/selected-bit and continuous/procedural conflicts reject with both source spans. Generated/hierarchical ownership and broader sizing/source-to-model coverage remain open. See the [RTL-019 report](prototype/corpus/results/rtl-019-continuous-driver-diagnostics-2026-11-19.md) and [regression](prototype/tests/test_continuous_driver_diagnostics.ps1).

On 2026-11-19, the separate DRAT checker's RUP propagation was changed to two-watched-literal propagation. The checker, proof, cache, corpus, and bundle regressions pass; a separate full-clause-scan RUP oracle accepts ten integrated proof artifacts, while no external-checker differential or checker performance benchmark has been run. The regression now also exhaustively checks all 512 two-variable formula sets and rejects 760 one-addition-then-empty traces from satisfiable formulas, including 224 candidate additions that individually destroy satisfiability; this bounded oracle does not close general checker soundness review. RTL-015's fixed-width concatenation row now has a three-member source vector, 64-value T-IR oracle, and checked induction bundle. RTL-007 now checks fill values at five widths, rejects X/Z fill forms before proof, and has a checked induction bundle. RTL-005 now has focused literal-only and mixed signal/unsized-decimal unary/binary +/− sizing checks: the mixed regression covers 8/16/40-bit contexts, signed/unsigned operands, explicit truncation, continuous/combinational/sequential assignment contexts, a non-vacuous symbolic reference query, and a fail-closed bitwise negative; the literal-only vector also has checked induction, bundle reopening, and independent full-scan RUP evidence. Broader mixed sizing, general sized-literal operator-context propagation, boundary matrices, and general IEEE 1800 sizing remain open. A Windows PowerShell 7 runner captures raw Phase 0 measurements; its host profile now keeps installed RAM (Windows installed-memory API or sourced user override) separate from OS-visible physical memory, covered by a passing isolated runner smoke regression. Eight proposed B-01..B-05 jobs now have functional preflight evidence; see [the draft jobs](prototype/benchmark/phase0-jobs.proposed.json), [preflight report](prototype/corpus/results/t029-runner-progress.md), and [saved proof/witness bundles](evidence/benchmark/preflight/). The proposed B-01/B-03 properties, B-04 cover intent/bound, and numeric time/memory policy need owner review before T029/T030 measurement.

The SAT bit-blaster and independent trace replay now support focused mixed-width sizing for arithmetic, relational, equality, bitwise, and conditional expressions. A six-property RTL fixture checks explicit signed/unsigned extension references end-to-end. These results do not close full IEEE 1800 sizing conformance or T016/T017/T018. See [expression width-extension evidence](prototype/corpus/results/t016-expression-width-extension-progress.md), [the mixed-width source fixture](prototype/corpus/source-model-vectors/bmc_mixed_width.sv), and [its regression](prototype/tests/test_bmc_mixed_width.ps1).

Bounded cover queries now include linear implication properties. `COVERED` requires an in-bound antecedent and consequent match, and the witness must pass independent replay. This result is nonvacuous reachability; full IEEE vacuity coverage counters and full SVA semantics remain open. The internal SAT kernel now includes a per-solve CDCL implementation with 1-UIP learning and nonchronological backjumping; a focused differential oracle now compares 5,400 queries with exhaustive assignment search; general soundness evidence remains open. See [the CDCL oracle](prototype/tests/test_sat_cdcl.ps1), [the cover implication regression](prototype/tests/test_bmc_cover_implication.ps1), and [T018 progress](prototype/corpus/results/t018-sat-kernel-progress.md).

RTL-027 now has bounded static-casez conformance evidence for overlapping patterns, three wildcard positions, exact T-IR masks/source mappings, default selection, and all 16 four-bit selector values. Runtime X/Z selector semantics remain unsupported. See [RTL-027 evidence](prototype/corpus/results/t017-rtl027-casez-wildcard-positions-2026-11-20.md).


RTL-023 now has bounded synchronous-reset conformance evidence: exhaustive state/input checks, held/released/reasserted multi-frame simulation, exact source mappings, and proof that reset does not gate an unreset state element. Asynchronous reset and four-state behavior remain unsupported. See [RTL-023 reset evidence](prototype/corpus/results/t017-rtl023-sync-reset-isolation-2026-11-20.md).

RTL-022 now has bounded evidence for shared-clock nonblocking semantics: 16 independent simultaneous pre-edge valuations, exact reset/data source mapping, and source-located rejection of blocking assignments in always_ff. See [RTL-022 nonblocking evidence](prototype/corpus/results/t017-rtl022-nonblocking-conformance-2026-11-20.md).

RTL-006 now has bounded evidence for direct sized signed/unsigned binary, octal, decimal, and hexadecimal literals. Zero/sign extension and truncation are checked by a 14-equation independent T-IR oracle and two bounded SAT assertions across continuous, always_comb, and always_ff assignments. General sized-literal operator-context propagation remains unsupported. See [RTL-006 sized-literal evidence](prototype/corpus/results/t017-rtl006-sized-literal-conformance-2026-11-20.md).

SVA-001/002 now have bounded source-level evidence for one posedge clock, exact concurrent assertion mapping, known-true pass, replay-validated known-false frame-0 witness, and negedge rejection before BMC. Other clocks/edges and full IEEE property-monitor semantics remain unsupported. See [SVA-001/SVA-002 evidence](prototype/corpus/results/t017-sva001-002-assertion-clock-2026-11-20.md).

SVA-003 now has bounded evidence for named scalar assumptions: a consistent assumption constrains all three sampled frames, while contradictory assumptions produce INCONSISTENT_MODEL_OR_ASSUMPTIONS. T-IR preserves identity and source mapping; temporal assumptions remain limited to the approved SVA subset. See [SVA-003 assumption evidence](prototype/corpus/results/t017-sva003-assumption-frames-2026-11-20.md).

RTL-028 now has bounded conformance evidence for nested static generate-if branches: both true/false levels, exact selected branch source locations, 640 independent input pairs, and four nonvacuous BMC assertions. Scoped declaration evidence remains separately linked from the coverage map. Runtime generate conditions remain unsupported. See [RTL-028 generate-if evidence](prototype/corpus/results/t017-rtl028-generate-if-conformance-2026-11-20.md).

RTL-029 now has bounded generate-for evidence for exact 0/1/3 iteration counts, stable scoped names/types, nonvacuous assertions, and source-located rejection of a nonadvancing genvar. The SM-031 bit/part-select and SM-036 repeated-declaration regressions also pass. Dynamic bounds and unsupported generated declaration forms remain outside the profile. See [RTL-029 generate-for evidence](prototype/corpus/results/t017-rtl029-generate-for-conformance-2026-11-20.md).

RTL-016 now has an independent numeric oracle for direct constant bit/part selects on ascending and descending eight-bit packed ranges: 2,304 value comparisons, T-IR/source-map checks, eight nonvacuous bounded passes, eight replayed false properties, and fail-closed dynamic/out-of-range/reversed-direction cases. Nested/indexed selects and broader widths remain outside this profile. See [RTL-016 packed-select evidence](prototype/corpus/results/t017-rtl016-packed-select-conformance-2026-11-20.md).

RTL-010 now has source-level evidence for unary `+`, `-`, `~`, and `!` on unsigned four-bit values, with all 16 input values independently checked, four nonvacuous bounded assertions, a replayed false-property witness, and an exhaustive SAT unary-minus oracle. Signed and wider cases remain open. See [RTL-010 unary evidence](prototype/corpus/results/t017-rtl010-unary-conformance-2026-11-20.md).

RTL-011–RTL-014 now have bounded mixed-width evidence across the tested 3-bit/2-bit signedness combinations: arithmetic carry/borrow, bitwise operations, comparisons, conditional branches, independent replay, and source-level explicit-extension properties. Wider/context-determined sizing and the noted source-vector gaps remain open. See [mixed-width evidence](prototype/corpus/results/t017-rtl011-014-mixed-width-conformance-2026-11-20.md).

RTL-017 covers constant `<<` and `>>` in the four-bit unsigned Phase 0 corpus. The frontend rejects `>>>` with a source location before emitting any formal status. SAT and replay retain internal `>>>` checks for the proposed extension and historical typed models. See [base shift evidence](prototype/corpus/results/rtl-017-shift-boundaries-2026-11-19.md) and [arithmetic right shift evidence](prototype/corpus/results/t017-rtl017-arithmetic-right-shift-extension-2026-11-20.md).

SVA-004 is Supported for the tested bounded scalar, sequence, and linear-implication cover subset: source witnesses replay, the independent finite oracle checks 900 assignments, and incomplete bounds remain UNKNOWN. Full IEEE vacuous-success coverage accounting is not implemented. See [SVA-004 evidence](prototype/corpus/results/t017-sva004-bounded-cover-conformance-2026-11-20.md).

T020 replay mutation checks now reject all 256 corrupted 3-bit/2-bit addition and subtraction witnesses, plus mutations to Boolean state traces and overlapped/non-overlapped cover witnesses with one- or two-term antecedents. `test_property_replay.ps1` passes; this remains bounded evidence and does not establish profile-wide replay soundness. See [T020 replay mutation evidence](prototype/corpus/results/t020-replay-single-bit-mutation-2026-11-20.md).
