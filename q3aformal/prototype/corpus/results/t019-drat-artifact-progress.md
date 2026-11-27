# T019 DRAT Artifact and Checker Progress

## 2026-11-21 sequential proof checking

The checker now applies each Delete Resolution Asymmetric Tautologies (DRAT) record as it arrives. The wrapper keeps the existing metadata validation, checks the declared record count, requires `proof_end`, and rejects subsequent data. The standalone command opens the artifact as a file stream. Its conjunctive normal form (CNF) hash remains bound to the data passed to the checker.

The checker regression passed the finite reverse unit propagation (RUP) and Resolution Asymmetric Tautology (RAT) oracles and added controls for missing trailers, trailing data, records after the empty clause, count mismatch, and CRLF line endings. The standalone command regression also passed the existing identity and configurable limit checks.

An engineering comparison checked the same 4,000,278-byte artifact on Windows. It repeats a valid addition and deletion 400,000 times before deriving the empty clause. All six runs accepted 800,001 records. PowerShell sampled the process private memory size with a 5 ms wait between samples.

| Binary | Executable SHA-256 | Highest sampled private memory per run (MiB) |
|---|---|---|
| Previous checker | `85de83b2f4e8052ea200aae7e3730860e9429e9cfc7c395a023cdfc535d4c7f5` | 73.91, 62.61, 62.59 |
| Sequential checker | `46ea18340a0428fe80c1898d2092d0eeaa0b84bde0b332246cee1fd83611d6f5` | 1.08, 1.07, 1.07 |

The workload isolates proof record buffering. Checks with a large active clause database and streaming certificate generation remain open.

## 2026-11-21 checker memory budget

The checker accepts a host memory policy and checks proposed allocations for the active clause vector and watched propagation tables. It also samples at fixed intervals during parsing, propagation and resolution. Windows callers use the process budget for standalone checks, generated-proof validation, cache rechecks and bundle proof revalidation. When the policy stops a check, the caller receives a resource-limit result before it can publish acceptance.

The standalone regression uses a valid sparse contradictory formula declaring 1,000,000 variables and sets `Q3A_MEMORY_LIMIT_MIB=16`. The estimated propagation-table allocation triggers `RESOURCE_LIMIT` with exit code 3 before allocation. The library test independently checks the proposed allocation through a deterministic callback and confirms that a small proof still passes. Both fixed checker ceilings and real process allocation failures remain distinct from invalid proof results.

The cache regression forces a memory stop, receives no proof data and can subsequently reuse the same valid entry. The reopening regression uses a valid replay trace padded with 20 MiB of JSON whitespace. It returns `UNKNOWN` with exit code 3 under the 16 MiB limit and `REVALIDATED` when the limit is removed. Existing bounded and induction memory controls also pass.

This is a sampled budget. A check may allocate memory between samples. Streaming certificate production and representative proof workloads with large active databases remain open.

## 2026-11-21 streamed induction proof production

The k-induction producer streams each conflict-driven clause learning (CDCL) proof addition into an exclusive staging directory under the output prefix's parent. The solver reports a completed record count only with an unsatisfiable verdict and a final empty clause within its record budget. Only then does the wrapper generate the artifact header and copy the proof body in blocks. The independent checker reads the completed staged artifact before publication. Temporary files are removed on regular exit, including an interrupted proof. New bundle creation copies these checked certificates in blocks.

The SAT regression compared emitted records with the buffered order and confirmed that a record-limit stop returned `UNKNOWN` with no completed count. It also passed 5,400 differential queries and 1,233 refutation checks. The integrated regressions passed depth-1 and depth-2 induction, replayed witnesses, standalone rechecks, bundle reopening and memory-limit controls. The cache regression confirmed byte-identical results on a hit and checked that the staging directory was removed.

This removes the duplicate proof-record vector from the integrated path and keeps the completed artifact on disk when no proof cache is requested. The solver and checker retain their active clauses. The optional cache still loads artifacts in memory, and the standalone proof producer still buffers its records. Peak memory on a large active proof remains unmeasured.

## Scope

This increment adds a standalone DIMACS-level proof-search utility, a separately implemented DRAT checker, a versioned artifact wrapper, and a bounded-depth restricted k-induction path from T-IR. It is partial T019 evidence only. It does not support the full approved RTL/SVA profile or the required end-to-end known-pass/known-fail evidence bundle.

## Implemented

- `prototype/checker/drat_prover.cpp` implements bounded deterministic DPLL proof search independently of the production watched-literal SAT solver. For an UNSAT CNF it emits a RUP-only DRAT refutation. SAT and exhausted-limit outcomes do not emit proofs.
- `prototype/checker/drat_checker.cpp` parses and checks DIMACS/DRAT independently of the SAT solver, including RUP and RAT additions and clause deletions. RAT checking searches every candidate literal for a valid pivot. The checker requires an empty clause and rejects incomplete proof streams.
- `prototype/checker/proof_artifact.cpp` wraps the proof in schema 2 with query kind, checker ID (`q3a-drat-checker-0.2`), model SHA-256, exact-CNF-byte SHA-256, and a record count. The checker compares these fields with caller-supplied expected metadata before checking the proof. `q3aformal-proofcheck --version` reports checker identity and artifact schema.
- `prototype/checker/proof_cli.cpp` provides create/check commands. Artifact creation self-checks before writing and refuses to overwrite the CNF input.
- `prototype/source/source_manager/main.cpp` adds `--prove-inductive` with optional `--k K` (default 1, maximum 10000). Supported assertion targets include scalar predicates, same-sample sequences of one-bit terms joined by `##0`, standalone scalar assertion sequences with fixed delays and positive bounded repetition, and assertion implications (`|->`/`|=>`) whose operands are one-bit linear sequences with fixed delays and positive bounded repetition. Each sequence expansion is capped at 4096 paths; the full target horizon plus K must fit within 10000 transitions. Assumptions include scalar predicates, same-sample sequences, and fixed-delay/bounded-repetition sequence and implication operands. A standalone sequence assertion must match at every property-start frame; where repetition offers multiple lengths, at least one complete match path must hold. Delayed scalar and implication assertions cannot use guarded `$past`. Non-overlapped properties use a successor frame and cannot contain guarded `$past`. Temporal assumption starts are included only when their complete maximum horizon fits the relevant proof window. A same-sample sequence such as `a ##0 b` is reduced to `a && b`; `(a ##0 b) |-> (c ##0 d)` becomes `(!a || !b || c) && (!a || !b || d)`, while `|=>` takes consequent predicates from the next frame. Variable delay ranges, delayed assumptions with guarded `$past`, and automata outside the supported linear path remain rejected. For depth K, both obligations cover property-start frames 0..K-1; the step assumes Q in frames 0..K-1 and checks frame K. Target lookahead is included in base/step transition counts. Base starts in the T-IR initial state, including generated `$past` validity initialization; step leaves every frame-zero state bit unconstrained. The command derives the model digest from serialized T-IR, hashes each exact CNF, uses k-specific query identities, writes checked DRAT artifacts, and reports `Q3A_INDUCTION_STATUS PROVEN` only when both obligations are UNSAT and checked.
- SAT models are decoded and replayed independently against T-IR equations, assumptions, and obligation semantics before they are saved. A validated base model produces `Q3A_INDUCTION_STATUS FAIL` and identifies the first reachable failing frame. A validated step model remains `NOT_<k>_INDUCTIVE`, because an induction countermodel may be unreachable.
- The base query applies generated history-valid initialization at frame zero. The step query leaves every initial state bit unconstrained, including generated `$past` history-valid state; replay follows the same rule. This is required for the induction hypothesis to cover arbitrary states, not only freshly initialized traces.
- Search has explicit node, record, variable, and recursion-depth limits; hitting a limit returns `UNKNOWN`. The default recursion-depth limit is 256.

At the initial same-sample checkpoint, the induction command rejected nonzero delayed sequences; that limitation was later extended to one fixed sample of delay for standalone scalar assertion sequences. Non-overlapped assertions and assumptions use successor samples, with incomplete assumption edges omitted beyond each finite obligation window. Guarded `$past` is encoded for scalar and same-sample overlapped properties; non-overlapped properties with guarded `$past` are rejected because the current property-level guard cannot express shifted operand validity. K-depth regression checks the full base prefix, k-step obligations, k-bound proof identities, invalid depth rejection, and replayed witnesses. The accepted result establishes the supported invariant for the generated T-IR transition model; source parsing, lowering, and bit-blasting remain trusted components.

## Test-first evidence

The new non-first-pivot RAT vector first failed because the checker assumed the first clause literal was the pivot. After the checker tried every candidate literal, the focused checker regression passed. The test suite also exercises RUP proofs, RAT additions, deletions, malformed/out-of-range/incomplete cases, proof-search SAT/UNKNOWN outcomes, artifact identity/schema failures, and CLI input-overwrite protection.

The guarded-`$past` induction extension followed the same test-first cycle: its new test first failed on the explicit “rejects history-guarded properties” diagnostic. After encoding the invariant `!history_valid || predicate`, it passed both a non-inductive countermodel case and an independently rechecked tautological base/step proof. Preserved logs, CNFs, DRAT artifacts, witness, and hashes are in `evidence/induction-guarded-past/README.md`.

The k-induction CLI extension was test-first as well: the added depth-2 test first failed with the prior fixed-arity usage error. It now passes base-prefix/step checks, rechecks both k-specific DRAT artifacts, verifies assumptions at every base and step frame, rejects depth 0, and records depth-2 known-pass and guarded-past witness evidence in `evidence/known-pass/k2/` and `evidence/induction-guarded-past/k2/`.

The induction replay extension was test-first: regressions first required independently validated base and step witnesses, a base `FAIL` status only for a replayed initialized trace, and an induction step that can begin with history-valid state true. The encoder initially applied the base initialization to both obligations; it now applies that constraint only to base. The independent replay checks signal widths, combinational and next-state equations, assumptions, base-prefix failure or step hypotheses plus terminal failure. Unit tests verify that the same history-valid initial state is rejected for base but accepted for a valid step model, and reject a step trace that violates its induction hypothesis. The full `test_inductive_proof.ps1` integration passed on 2026-11-16, including standalone DRAT checks and saved witnesses.

Validation commands:

```powershell
.\prototype\tests\test_drat_checker.ps1
.\prototype\tests\test_drat_cli.ps1
.\prototype\tests\test_inductive_proof.ps1
.\prototype\tests\test_inductive_sva_implication.ps1
```

Both commands passed after the fix on 2026-11-16. The checker suite compiles a standalone C++ test executable; the CLI suite builds the proof utility in a temporary directory and removes its outputs.

`prototype/tests/test_inductive_proof.ps1` checks generated artifacts again using the separately built proof-checker executable. It also checks a freely varying scalar property whose base obligation is SAT and whose decoded witness assigns `a=0`, rejection of sequence properties, guarded `$past` induction with independent artifact rechecking, output overwrite protection, and preservation of model identity. This test passed on 2026-11-16.

The schema-2 corpus in `evidence/checker-corpus/` records an accepted valid artifact and rejected one-literal-defect, truncated-metadata, and wrong-checker-identity artifacts, including diagnostics, exit codes, and SHA-256 fingerprints. `prototype/tests/test_checker_corpus.ps1` checks that the saved report matches the current corpus and checker identity. This closes T023's recording requirement; it is still a small synthetic CNF fixture rather than a broad RTL-derived or independently authored soundness corpus.

After the schema-2 corpus, guarded-past induction, and scalar k-induction changes, all 17 PowerShell scripts under `prototype/tests/test_*.ps1` passed sequentially on 2026-11-16. The saved k=1 and k=2 schema-2 known-pass base/step artifacts were rechecked directly with `q3a-drat-checker-0.2`; all four returned `Q3A_PROOF_CHECK ACCEPTED` under their matching query identities.

## CDCL-generated proof-log integration

`Solver::solve()` can now record each learned clause and append the final empty clause for an assumption-free UNSAT query. Proof recording rejects temporary assumptions; the caller must encode them as unit clauses in the exact CNF so every proof step is checkable against that CNF. The integrated `--prove-inductive` path enables this mode, writes the exact CNF and CDCL-generated RUP additions into the existing schema-2 artifact, then reopens the artifact through the separate DRAT checker. The integrated path caps records at 1,000,000; limit exhaustion discards the partial log and yields `UNKNOWN`. An incomplete log cannot produce `PROVEN`. The standalone `q3aformal-proofcheck --create-drat` path remains its separate bounded DPLL generator.

`test_sat_cdcl.ps1` asks the independent DRAT checker to validate CDCL logs for a crafted 1-UIP UNSAT CNF and a 4-pigeon/3-hole UNSAT CNF; both proofs are accepted. It also gets independent checker acceptance for 1,233 random UNSAT proof logs, with each temporary assumption encoded as a CNF unit. The same test differentially checks 5,400 deterministic SAT queries against exhaustive assignment search, verifies a nonchronological backjump skips an irrelevant decision level, checks decision/propagation/proof-record limits, rejects temporary-assumption proof logging, and confirms incomplete logs are discarded. `test_inductive_proof.ps1` passed on 2026-11-17 after integration, including k=1 and k=2 base/step artifacts rechecked with the standalone checker, guarded `$past`, replayed countermodels, and invalid-depth rejection.

This closes the duplicate DPLL proof search for scalar k-induction queries, but the CDCL implementation remains in the trusted proof producer and is not itself formally verified. Independent DRAT checking validates emitted refutations, not RTL-to-T-IR translation or the SAT engine's general correctness. T019 remains open for broader SVA/invariant support, checker review/corpus, and end-to-end evidence.

## Gaps before T019 can close

- Extend induction beyond the supported bounded linear paths to branching/non-linear automata, more guarded temporal cases, and user-supplied complete invariants; validate broader interactions among these forms.
- Expand the independently authored valid/invalid/malformed artifact corpus beyond the synthetic fixture and conduct structural/soundness review. Checker identity/versioning and T023's minimum saved verdict set now have evidence, but the corpus is not comprehensive.
- Preserve broader induction countermodels and proof artifacts in reviewable bundles as induction support expands beyond scalar one-step properties.
- Expand independent replay and malformed-witness/differential coverage beyond the currently supported bounded linear sequences and implications. Replaying a saved BMC trace checks the witness against serialized T-IR without rerunning SAT; separate no-witness bounded-pass/cover-miss bundle reopening can regenerate and reexecute compatible queries. Neither path validates source-to-T-IR translation.
- Demonstrate separate known-pass and known-fail end-to-end jobs and produce required evidence bundles.

## 2026-11-19 checker propagation update

The independent DRAT checker's RUP propagation now uses two watched literals with an assignment queue. This removes the prior full-formula rescan after every propagated assignment; each RUP query still initializes its watch database, and RAT checking still examines relevant resolvents. No performance claim is made until measured on the approved Phase 0 benchmark inputs. Regression evidence is recorded below; no external-checker differential evidence exists, so T019 remains open and no general soundness claim follows from this code change.

The updated implementation subsequently passed `test_drat_checker.ps1`, `test_drat_cli.ps1`, `test_checker_corpus.ps1`, `test_inductive_proof.ps1`, `test_proof_cache.ps1`, and `test_bundle_reopen.ps1`. The bundle regression initially classified the old known-pass bundle as `HISTORIC` because its saved proof-checker source fingerprint correctly no longer matched the updated checker. A new k=1 known-pass bundle was generated with the current build and reopened; both base and step DRAT artifacts were accepted. The regression now targets that current bundle, while earlier captures remain historical. This is focused regression evidence only; it is not an external checker comparison or a general soundness proof.

The known-pass and known-fail demonstration jobs are preserved in `evidence/known-pass/` and `evidence/known-fail/` (T021/T022); schema-2 evidence includes k=1 artifacts under `evidence/known-pass/schema2/` and k=2 artifacts under `evidence/known-pass/k2/`. Corrected arbitrary-state induction and replay results are preserved in [`evidence/induction-replay-2026-11-16/`](../../evidence/induction-replay-2026-11-16/README.md). Earlier guarded-past evidence remains as historical pre-fix output and is superseded by that bundle. T019 and the overall proof-completion goal remain open. The command emits `PROVEN` only for checked scalar/same-sample sequence and supported implication assertions over the generated T-IR model; it does not change bounded BMC statuses or certify the full RTL source translation.

## 2026-11-17 single-sample overlapped implication induction increment

At this earlier increment, the induction command accepted a restricted overlapped implication when both sides were exactly one one-bit predicate sampled in the same cycle, with no delay or repetition. It lowered that property to the invariant `!antecedent || consequent`. A generated `$past` validity guard, when present in either predicate, qualified the entire invariant. Same-cycle overlapped implication assumptions used the same per-frame clause form. Non-overlapped `|=>`, delayed sequences, repetition, multi-term sequences, temporal assumptions, and user-supplied invariant predicates were still unsupported at that checkpoint.

`test_inductive_sva_implication.ps1` checks a combinational known-pass implication, a false implication with a reachable base counterexample and independent replay, an implication assumption constraining the proof query, and a stateful implication with a guarded `$past` consequent. The test passed after a fresh build on 2026-11-17. The prior `test_inductive_proof.ps1` regression also passed with standalone DRAT rechecks; `test_bmc_property_queries.ps1` passed after adjusting its Windows PowerShell native-stderr capture for the expected overwrite rejection. This expands only the invariant encoding subset; it does not implement general SVA monitor induction or certify source-to-T-IR semantics.

## 2026-11-17 same-sample `##0` induction increment

The induction encoder now supports non-empty linear SVA sequences whose one-bit terms are sampled in the same frame (`##0`, with each term repeated exactly once). Scalar sequence assertions are represented as a conjunction. For an overlapped implication, the antecedent conjunction is negated in each clause and each consequent term contributes one clause; a generated history-valid guard qualifies the complete predicate. Assumption constraints and independent replay check all terms against their T-IR automata. Nonzero delay, repetition beyond `[1:1]`, `|=>`, and general temporal monitor induction remain unsupported.

`test_inductive_sva_implication.ps1` passed after a fresh build on 2026-11-17, including proven and false scalar `##0` sequences, proven multi-term implication and scalar/implication assumptions, a replay-validated base counterexample, guarded `$past`, and standalone DRAT rechecks. `test_inductive_proof.ps1` passed for k=1/k=2 and unsupported delayed sequences; `test_bmc_property_queries.ps1` passed for bounded scalar/sequence properties, assumptions, replay, and covers. This is a narrow same-sample sequence reduction, not general SVA induction.

## 2026-11-17 restricted non-overlapped induction increment

`|=>` assertions and assumptions now support scalar or same-sample `##0` antecedent/consequent sequences. The encoder treats the consequent as a predicate at the successor frame. The base obligation checks K property-starts using K transitions; the step uses K hypotheses and checks the next property-start using K+1 transitions. Non-overlapped assumptions are constrained only at start frames whose successors are inside the relevant finite proof window. Independent replay reports the violated property-start frame and validates the successor-sample predicate. Non-overlapped properties with guarded `$past` remain rejected because history validity is currently stored as one property-level guard and cannot represent its shifted sampling point. The extra lookahead means K is limited to 9999 for non-overlapped assertion targets under the existing 10,000-transition cap.

`test_inductive_sva_implication.ps1` passed on 2026-11-17 with known-pass and known-fail `|=>` assertions, proof under a non-overlapped assumption at k=1/k=2, assumption-constrained replay, and standalone DRAT rechecks. `test_inductive_proof.ps1` passed on the same implementation for existing scalar/overlapped k=1 and k=2 cases, guarded `$past`, and rejection of delayed sequences. This does not implement general sequence-monitor induction.

## 2026-11-17 fixed one-sample scalar assertion-sequence increment

K-induction now supports a standalone scalar assertion sequence whose linear automaton has exact single matches, one-bit terms, and a fixed cumulative sample offset of zero or one. A `##1` sequence predicate is evaluated at its actual successor frame. Delayed sequence assertions cannot use guarded `$past`; assumptions and implication operands remain same-sample; offsets above one, repetition outside exact `[1:1]`, and general sequence-monitor induction remain unsupported. The target uses one lookahead transition, so `k` is limited to 9999 under the current transition limit. Independent replay follows the same property-start-to-match semantics and validates delayed failures before classifying them.

The regression's positive delayed case is the tautological `1'b1 ##1 1'b1` sequence, while the signal-dependent `a ##1 b` assertion is expected to produce a replay-validated base failure. The distinction is deliberate: a standalone SVA sequence assertion must match at every start frame; it does not treat a false first term as a vacuous implication antecedent. `test_inductive_sva_implication.ps1`, `test_inductive_proof.ps1`, and `test_bmc_property_queries.ps1` passed after the change. Existing bounded delay/repetition support is unchanged. This increment expands only the generated T-IR induction subset, not general SVA sequence induction or source-to-T-IR conformance.

## 2026-11-17 fixed-delay and exact-repetition scalar assertion increment

Standalone scalar assertion induction now accepts linear sequences with fixed nonnegative delays and exact positive repetition counts, provided the total sample horizon plus `k` fits within the existing 10000-transition cap. The encoder expands repeated predicates at each required sample, and the independent replay engine checks the same fixed path. Variable delay ranges and repetition ranges remain unsupported; assumptions and implication operands remain same-sample; delayed scalar assertions cannot use guarded `$past`.

The regression uses the known-pass sequence `1'b1[*2] ##2 1'b1[*2]` at `k=1` and `k=2`, plus a signal-dependent false sequence whose base witness is independently replayed. `test_inductive_sva_implication.ps1`, `test_inductive_proof.ps1`, and `test_bmc_property_queries.ps1` passed on 2026-11-17. This extends only standalone scalar assertion sequences and does not implement variable-path monitor induction or complete source-to-T-IR conformance.

## 2026-11-17 bounded variable-repetition scalar assertion increment

K-induction and independent replay now support positive bounded repetition ranges on standalone scalar assertion sequences. The encoder enumerates each legal repetition-count combination (maximum 4096 paths), builds the conjunction for each path, and ORs the path matches. Replay independently searches the same automaton choices. The target's maximum sequence horizon plus `k` must remain within the 10000-transition limit. Variable delays, delayed implication operands/assumptions, delayed `$past` guards, and branching automata beyond the linear repetition ranges remain unsupported.

The known-pass property `1'b1[*1:2] ##1 q` uses a toggling state bit: either of the two repetition paths reaches a true `q` sample. A separate `a[*1:2]` assertion produces a replay-validated base failure. `test_inductive_sva_implication.ps1`, `test_inductive_proof.ps1`, and `test_bmc_property_queries.ps1` passed on 2026-11-17. This adds bounded path choice only for standalone scalar assertion targets and does not implement general sequence-monitor induction or certify source-to-T-IR equivalence.

## 2026-11-17 fixed-delay implication sequence implementation

The induction front end, CNF encoder, and independent replay now accept assertion implications whose antecedent and consequent are one-bit linear sequences with fixed delays and positive bounded repetition. Every possible antecedent match endpoint creates a consequent obligation; `|->` starts that consequent at the endpoint, while `|=>` starts it one sample later. The proof horizon includes the maximum antecedent offset, the implication delta, and the maximum consequent offset. Sequence path count remains capped at 4096, and the complete target horizon plus `k` must fit within 10000 transitions. Assumptions accept the same bounded fixed-delay linear sequence subset, with starts constrained only when their full maximum horizon fits the proof window. Guarded `$past` remains available only for the existing same-sample property forms; delayed implication operands with a property-level history guard are rejected. Variable delay ranges and general branching automata remain unsupported.

The SVA induction fixture includes proven delayed/repeated overlapped and non-overlapped implications, plus a false delayed implication whose base counterexample must replay. The earlier rejection-only regression for `(a ##1 b) |-> (c ##2 d)` now expects a replayed reachable failure. This is bounded linear sequence matching over generated T-IR; it does not implement general temporal-monitor induction or establish source-to-T-IR equivalence.

## 2026-11-18 bounded fixed-delay assumption increment

Induction assumptions now accept standalone linear sequence assumptions and `|->`/`|=>` assumptions whose operands use fixed delays and positive bounded repetition. A standalone assumption requires at least one complete match path at each applied start. An implication assumption creates a consequent obligation for every antecedent match endpoint. In both the encoder and independent replay, only starts whose full maximum horizon fits within the current base/step proof window are applied; incomplete tail starts are omitted consistently. Delayed assumptions with a guarded `$past`, variable delay ranges, non-linear automata, and temporal forms outside this subset remain unsupported.

The new vector proves an assertion from a delayed sequence assumption and another from a delayed implication assumption. It also checks a false assertion under both assumptions and requires its base witness to replay independently, confirming that the witness satisfies the temporal environment. `test_inductive_sva_implication.ps1`, `test_inductive_proof.ps1`, and `test_bmc_property_queries.ps1` pass with this change. The BMC path retains its existing incomplete-boundary reporting; the new induction-specific rule applies only when deciding which complete assumption starts constrain the finite proof obligation.

## 2026-11-18 finite bounded sequence-delay range support

The SVA lowerer now accepts finite `##[m:n]` delay ranges whose endpoints are nonnegative literals or resolved constants and satisfy `m <= n`. It lowers each non-degenerate range to a true-predicate repeated term, which gives the existing linear sequence matcher one path for each legal endpoint. This makes the range available consistently to bounded model checking, k-induction assertions, implication operands, assumptions, and independent replay. Existing limits still apply: at most 4096 expanded match paths, a maximum induction horizon of 10000 transitions including `k`, and no unbounded delay range. A property-level guarded `$past` still cannot qualify delayed sequence operands.

The focused SVA regression now checks ##[0:1], ##[1:2], and ##[2:2], plus overlapped/non-overlapped implications, a bounded delay in the consequent, sequence and implication assumptions, a replayed standalone-sequence BMC failure, and a replayed induction failure. test_inductive_sva_implication.ps1, test_inductive_proof.ps1, and test_bmc_property_queries.ps1 pass. This validates the tested range slice only; it is not full IEEE 1800 sequence conformance.

## 2026-11-18 standalone linear sequence assertions in BMC

The bounded query encoder now handles standalone linear sequence assertions as a required match at each property-start frame. It ORs legal sequence paths for that start, skips starts whose complete maximum horizon is outside the finite bound, and marks the query boundary incomplete. Counterexample candidate frames identify the property start; the independent replay checks the same sequence-match failure semantics. This reuses the existing bounded sequence matcher and supports fixed delays, finite bounded delay ranges, and positive bounded repetition in the enabled one-bit linear subset.

The regression checks a bounded-delay standalone sequence counterexample, its independently replayed witness, and the incomplete-tail status. test_inductive_sva_implication.ps1 and test_bmc_property_queries.ps1 pass after the implementation. This does not add non-linear automata or full IEEE 1800 property-monitor semantics.

## 2026-11-19 independent RUP cross-check of integrated induction artifacts

Added `prototype/tests/test_drat_independent_full_scan.ps1`, a test-only RUP oracle that scans all clauses from the beginning after every assignment. It uses a different propagation implementation from the product checker's two-watched-literal lists. The oracle validates the exact CNF SHA-256, checker metadata, proof-record count, every RUP addition, and derivation of the empty clause for the B-01, B-03, RTL-015, and RTL-007 base/step proof artifacts. It also checks a tiny entailment and a false empty-clause claim against exhaustive truth-table enumeration.

The regression passes for all ten integrated proof artifacts. This is independent algorithmic evidence for these RUP-only artifacts and small logic cases. It is not a general DRAT checker, does not validate RAT/deletion records, is not an external trusted implementation, and does not establish general checker soundness or RTL-to-T-IR correctness.

## 2026-11-19 watched-literal relocation fixture

`prototype/tests/drat_checker_test.cpp` now cross-checks 408 positive RUP additions over all satisfiable two-variable formula sets and 1,414 positive additions over satisfiable formulas in a deterministic three-variable sample against an independently implemented naive full-clause-scan oracle. It also includes a hand-authored, satisfiable five-variable CNF whose first RUP addition propagates through a ternary clause and forces a watched-literal relocation. The production checker must accept both additions and a subsequent deletion, then reject an appended empty clause. `test_drat_checker.ps1` passes with this case and the existing 760/2,626 SAT-preservation traces. This is bounded regression evidence, not exhaustive watch-list coverage, a trusted external-checker comparison, or a general soundness proof. See [`evidence/checker-corpus/drat-watched-rup-relocation-2026-11-19.md`](../../evidence/checker-corpus/drat-watched-rup-relocation-2026-11-19.md).

## 2026-11-20 independent RUP/RAT differential

The checker regression now compares the production watched checker against a separate full-clause-scan RUP/RAT oracle for every candidate addition over 128 deterministic three-variable formula masks. It checks 3,328 cases: the independent oracle and checker accept the same 2,866 and reject the same 462, including 750 candidates valid by RAT but not RUP. `prototype/tests/test_drat_checker.ps1` passes. This improves bounded classification evidence but does not close general proof-trace soundness, external trusted-checker differential, or complete Phase 0 proof coverage. See [`evidence/checker-corpus/drat-rat-differential-2026-11-20.md`](../../evidence/checker-corpus/drat-rat-differential-2026-11-20.md).
