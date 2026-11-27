# Q3AFormal Proof Artifact Prototype

This directory contains an experimental Q3A-owned proof-search utility, a separately implemented DRAT checker, and a versioned proof-artifact wrapper. The standalone `q3aformal-proofcheck --create-drat` command uses bounded deterministic DPLL. Integrated k-induction records Reverse Unit Propagation (RUP) additions from the production CDCL SAT query and passes them to the independent checker. The checker is separate from the bounded RTL/SVA query pipeline.

`--check-drat` reads the artifact from disk one line at a time. The checker applies each record to the active clause database, verifies the declared record count and trailer, and publishes acceptance only after the complete artifact has been consumed. Integrated induction records learned clauses directly into a staging file. The solver and checker still keep their active clause databases in memory.

The checker rejects a zero-record artifact before reading the query and rejects any noncomment record beyond the declared count before parsing its literals or checking the inference. A short body still fails the declared count check after the trailer is read. The proof search and checker likewise reject a DIMACS token that starts a clause beyond the header count.

The Windows memory policy is used by standalone checking, generated-proof validation, cache rechecks and bundle proof revalidation. It checks estimated allocations for the clause database and propagation tables and samples memory during parsing and checking. `Q3A_MEMORY_LIMIT_MIB` can lower the process budget. A standalone check that reaches the budget reports `RESOURCE_LIMIT` with exit code 3. Induction and bundle revalidation report `UNKNOWN`; a resource-limited cache lookup leaves its entry in place. This policy samples memory and estimates some allocations. Allocations can still occur between samples.

## Build

From the repository root in PowerShell:

```powershell
.\prototype\checker\build.ps1
```

The build creates `prototype/bin/q3aformal-proofcheck.exe`. It uses C++17 and Windows CNG for SHA-256. No external SAT solver or proof checker is linked. To select a compiler, pass `-Compiler '<path-to-g++.exe>'`.

## Commands

Create an artifact for a UNSAT DIMACS query. The caller supplies the model digest and query kind; the command computes the SHA-256 of the exact CNF bytes:

```powershell
$modelHash = '<64 hexadecimal digits for the exact model identity>'
& .\prototype\bin\q3aformal-proofcheck.exe `
    --create-drat .\obligation.cnf .\obligation.q3adrat `
    --model-sha256 $modelHash --query-kind induction-base
```

The standalone proof search uses deterministic DPLL and emits a RUP-only DRAT refutation. Before writing it, the CLI checks the artifact with the separate checker. SAT input produces `SAT_NO_REFUTATION`; exhausted limits produce `UNKNOWN`. Neither result is a proof.

Check an artifact against exact CNF bytes and expected metadata:

```powershell
& .\prototype\bin\q3aformal-proofcheck.exe `
    --check-drat .\obligation.cnf .\obligation.q3adrat `
    --model-sha256 $modelHash --query-kind induction-base
```

The checker validates the artifact schema and record count, compares expected model/query identity, checks each proof addition as RUP or Resolution Asymmetric Tautology (RAT), processes deletions, and requires derivation of the empty clause. RUP unit propagation uses per-query two-watched-literal lists instead of rescanning every clause after each assignment. RAT still checks candidate pivots and resolvents against the current database. A valid artifact yields `Q3A_PROOF_CHECK ACCEPTED`; a rejected artifact returns a nonzero exit code.

The RUP workspace uses a 32-bit head index per literal and two fixed watch slots per clause. Watch relocation rewires existing links without allocating memory. The checker estimates space for the watch tables, assignments, and propagation queue before allocating the workspace, and polls the live budget during propagation.

The checker reads CNF and proof input lines in fixed-size chunks. A line above the default 64 MiB byte ceiling or an allocation blocked by the host policy returns `RESOURCE_LIMIT`. This includes proof headers, records and trailers. The active clause database remains in memory.

The standalone `--check-drat` and `--create-drat` commands hash and parse the CNF through the same buffered Windows file handle, which denies writes across all reads. A large text file can fit in a smaller RAM budget when its active clauses fit. The creator applies the host budget during proof search and independent checking, and returns `UNKNOWN` on a resource stop. It writes the serialized certificate to temporary storage beside the destination, releases the generated records, and publishes the certificate only after checking succeeds. The active clauses and search records still occupy RAM during proof search.

The Phase 0 checker applies safety ceilings of 1,000,000 declared variables, 1,000,000 CNF clauses, 1,000,000 proof records, and 10,000,000 literals in either the CNF or proof. Library callers may inject lower `CheckerLimits` for validation; an exact-limit proof is accepted. Exceeding a ceiling returns `Q3A_PROOF_CHECK RESOURCE_LIMIT` (exit 3), which is inconclusive and distinct from an invalid proof. Integrated induction maps this outcome to `UNKNOWN`, never `PROVEN`. Artifact parsing accepts both LF and CRLF line endings. See [resource-limit and Windows artifact evidence](../../evidence/checker-corpus/drat-resource-limits-and-crlf-2026-11-19.md).

On Windows, both proof commands accept long input and output paths. Creation stages the proof next to its destination, rechecks the staged bytes, and refuses to replace its input clause file.

## Artifact identity

The current checker is `q3a-drat-checker-0.2` and accepts artifact schema 2. The schema stores `query_kind`, `checker_id`, `model_sha256`, `query_sha256`, a proof-record count, and the DRAT body. `query_sha256` covers the exact input CNF bytes, so changing whitespace or comments changes the query identity. The checker compares checker identity and model/query metadata with the values expected by the check command. `--version` prints the checker identity and supported artifact schema.

The standalone check command denies concurrent writes to both the query and the proof while checking them. Integrated induction derives the expected query hash from the solver's DIMACS serialization, matches it against the locked staged query, and holds the query and proof locks until publication. On a cache hit, it also matches the staged proof against the digest of the artifact accepted by the cache checker.

The schema-2 acceptance fixture and recorded valid/rejected verdicts are in [evidence/checker-corpus](../../evidence/checker-corpus/verdicts.md). This is a small checker-format fixture, not evidence that arbitrary RTL has been translated soundly.

The standalone `q3aformal-proofcheck` commands do not derive a model digest from T-IR, validate that an arbitrary CNF came from that model, or derive a query kind from an induction obligation. Those relationships remain the caller's responsibility for the generic CNF CLI. The integrated `--prove-inductive` command derives the T-IR digest and creates base/step CNFs itself.

## Current limits

- Integrated k-induction supports scalar predicates, same-sample `##0` sequences, scalar assertion sequences, and implication operands with fixed delays, finite literal or resolved-constant ranges `##[m:n]`, and positive bounded repetition on linear match paths. Each sequence is limited to 4,096 expanded paths; the full target horizon plus `k` must fit 10,000 transitions. Assumptions use the same bounded sequence profile and apply only at starts whose maximum horizon fits the proof window.
- T-IR 0.4 supports guarded `$past` in accepted finite delayed sequences and implication operands by applying separate history guards at each operand's sequence start. Unbounded delay ranges, non-linear automata, automatic invariant strengthening, user-supplied invariants, and other unsupported temporal forms remain outside the profile.
- Base applies generated history-valid initialization; the induction step leaves frame-zero state unconstrained. SAT models are independently replayed before status publication. A replayed base witness is `FAIL`; a replayed step countermodel is `NOT_<k>_INDUCTIVE` because it may be unreachable. `PROVEN` applies to the generated T-IR model, not to source-to-T-IR semantic correctness.
- The ordinary `--bmc` flow remains bounded and does not consume proof artifacts. A checked UNSAT CNF proves only that exact Boolean query unsatisfiable; it does not establish an RTL property by itself.
- The integrated SAT model search is capped at 1,000,000 decisions and 10,000,000 propagations; CDCL proof recording is capped at 1,000,000 additions. The standalone DPLL search has separate node, record, variable, and depth limits. Exhaustion reports `UNKNOWN`, and incomplete logs are discarded.
- The watched-literal checker has focused local regression evidence. `prototype/tests/test_drat_independent_full_scan.ps1` adds a separately written, naïve full-clause-scan RUP oracle that accepts ten B-01/B-03/RTL-015/RTL-007/RTL-005 induction proof artifacts and checks exact CNF hashes, metadata, proof-record counts, and empty-clause derivation; tiny entailment and false-empty cases are also compared with exhaustive truth tables. `prototype/tests/drat_checker_test.cpp` exhaustively enumerates all 512 formula sets over two variables and rejects 760 one-addition-then-empty traces from satisfiable formulas, including 224 candidates that individually destroy satisfiability. It also checks 2,626 candidate traces over 128 deterministic three-variable formula masks, rejecting all purported refutations from satisfiable formulas, including 397 candidates that individually destroy satisfiability. Results and limits are recorded in `evidence/checker-corpus/drat-sat-preservation-2026-11-19.md` and `evidence/checker-corpus/drat-three-variable-sat-preservation-2026-11-19.md`. These independent oracles are bounded evidence, not a general DRAT checker proof. No external trusted-checker differential or general soundness review has been performed, and checker performance has not been benchmarked. DRAT remains an evaluation candidate, not the frozen product format.

The regression also checks a multi-step satisfiable trace with two RAT additions, two deletions, and a final empty-clause attempt. It asserts that the entire non-empty prefix was processed before the checker rejects the empty clause as neither RUP nor RAT. See `evidence/checker-corpus/drat-three-variable-sat-preservation-2026-11-19.md`.

The checker unit suite also compares positive RUP verdicts against an independently implemented full-clause-scan oracle: 408 additions across all satisfiable two-variable formula sets and 1,414 additions across satisfiable formulas in a deterministic three-variable sample. A separate two-addition chain requires a watched literal in a ternary clause to move during propagation, then processes a deletion and rejects a false empty-clause claim. In addition, 3,328 three-variable candidate additions across 128 deterministic formula masks are classified by independent full-scan RUP/RAT logic and compared with the production checker; 750 accepted cases require RAT rather than RUP. These are bounded algorithmic checks, not exhaustive watch-list coverage or an external-checker differential; see `evidence/checker-corpus/drat-watched-rup-relocation-2026-11-19.md` and `evidence/checker-corpus/drat-rat-differential-2026-11-20.md`.

## Regression commands

```powershell
.\prototype\tests\test_drat_checker.ps1
.\prototype\tests\test_drat_cli.ps1
.\prototype\tests\test_inductive_proof.ps1
.\prototype\tests\test_drat_independent_full_scan.ps1
```

These tests cover selected RUP/RAT additions, non-first RAT pivots, deletions, invalid or incomplete evidence, proof-search limits, schema and identity mismatches, the saved checker corpus, and SAT input. They do not establish general checker correctness or end-to-end RTL proof correctness.

The checker regression also covers tautological RUP additions, duplicate literals, normalized deletion lookup with reordered/repeated literals, and rejection of an empty-clause claim after a tautology is added to a satisfiable CNF. See [clause-normalization edge evidence](../../evidence/checker-corpus/drat-clause-normalization-2026-11-20.md). This is a focused one-variable extension to the existing bounded checker corpus, not a general soundness proof.

The multi-step differential replays 1,920 prefixes from 160 deterministic four-variable formulas. The full-scan oracle evaluates each terminal empty clause against the current clause multiset, and an exhaustive 16-assignment check verifies satisfiability preservation for the accepted additions. Results include 399 accepted refutations, 1,521 rejected empty clauses, 207 RAT-only additions, 197 rejected additions, 751 rejected deletions, and 211 deletions of one copy of a duplicate clause. The oracle uses the pivot-retaining RAT test defined in the [DRAT-trim paper](https://www.cs.cmu.edu/~mheule/publications/drat-trim.pdf).
