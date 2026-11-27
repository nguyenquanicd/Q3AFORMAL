# Q3AFormal Phase 0 Benchmark Plan

**Status:** The owner approved the exact jobs and limits on 2026-11-21. All eight jobs have recorded measurements. See the [benchmark report](../../evidence/benchmark/benchmark-report.md).

## Execution-readiness update (2026-11-19)

The exact proposed project inputs, commands, expected outcomes, and diagnostic matches are collected in [`prototype/benchmark/phase0-jobs.proposed.json`](../../prototype/benchmark/phase0-jobs.proposed.json). This is a review draft, not an approved measurement manifest. Preflight checks confirmed the expected formal outcomes and independently reopened the saved evidence for B-01 through B-04. B-05 checks each unsupported construct with `--lower-project`; all stop during parsing/lowering before a proof query is started. The source identities and regression command are listed in the [preflight evidence index](../../evidence/benchmark/preflight/README.md). These checks establish job correctness and are not timing or memory measurements.

The historical preflight used the owner-supplied 16 GB installed-memory label. The owner subsequently approved the limits in the [threshold record](benchmark-threshold-proposal.md).

| ID | Preflight evidence | Current readiness |
|---|---|---|
| B-01 | `prototype/counter4.q3a`, property `p_wraps_to_zero`: `PROVEN`; both base and step DRAT artifacts were accepted when the bundle was reopened. | Draft job is executable; expected invariant/property and proof scope need owner review. |
| B-02 | `prototype/counter4-fail.q3a`, property `p_wraps_to_zero`, one transition: `BOUNDED_FAIL`; witness replay validated, and reopening the bundle revalidated the trace. | Draft job is executable; the result is bounded and specific to the saved model/assumptions. |
| B-03 | `B03_casez_decode`: `PROVEN`; base and step DRAT artifacts were accepted when the bundle was reopened. Its priority-aware property was checked against all 16 selector encodings. | Draft job is executable; owner review of the property is pending. |
| B-04 | `B04_handshake_cover`, property `p_cover_transfer`, one transition: `COVERED`; witness replay validated, and reopening the bundle revalidated the trace. | Draft job is executable; owner review of cover intent and bound is pending. |
| B-05 | Four negative jobs reject `disable iff`, a multi-clock consequent, unlisted `$rose`, and X/Z data with source-located parse errors. | Draft jobs are executable; diagnostic expectations match preflight output. |

The [approved job manifest](../../prototype/benchmark/phase0-jobs.approved.json) supersedes the draft for measurements. The [benchmark report](../../evidence/benchmark/benchmark-report.md) compares the raw counters with the frozen thresholds.

## Purpose

Measure a narrow vertical slice without generalizing results beyond the tested designs and hardware. Each benchmark has a known expected result and source-to-model evidence. No third-party formal tool is an oracle or runtime dependency.

## Benchmark designs

| ID | Design | Expected result | Main evidence |
|---|---|---|---|
| B-01 | counter4_pass: 4-bit modulo counter with synchronous reset | PROVEN | Checked base/induction-step or invariant evidence; reset model and transition corpus |
| B-02 | counter4_fail, which wraps to one instead of zero | `BOUNDED_FAIL` | Replayed counterexample within one transition and exported waveform |
| B-03 | casez_decode: packed input decoder with static wildcard patterns | PROVEN for the decoder-to-output invariant | casez match vectors, elaborated pattern, property evidence |
| B-04 | One-entry valid/ready buffer, with an accepted input followed by an accepted output | `COVERED` within one transition | Replay validates the two sampled handshake events |
| B-05a–d | Separate projects for `disable iff`, multiple clocks, the unlisted `$rose` function, and X/Z data literals | Exit code 1 with the corresponding source diagnostic | Parsing or lowering stops before a formal query |

All source files are independently authored for Q3AFormal. Record source hashes and provenance in the checked-in corpus.

## Pre-measurement freeze

Before collecting runtime or memory measurements, complete:

1. Exact benchmark RTL/SVA source and source hashes.
2. Expected statuses and the proof/witness evidence required for each run.
3. Named Windows x64 host profile: CPU model/core count, installed memory, OS build, compiler/version, build configuration.
4. Time limit, memory limit, and any per-run solver/query limits.
5. Run configuration, Q3A build ID, and profile/schema versions.

Do not report a performance pass/fail until the numeric limits are approved and frozen. If a threshold is not approved, report raw measurements without a threshold judgment.

## Measurement record

For each run, save elapsed time, peak resident memory, solver/model sizes where available, status, build ID, source/model/query hashes, resource limits, and checker/replay verdict. Include timeout, resource-limit, unsupported, and engine-error outcomes in the report.

## Terminology

| Abbreviation | Meaning |
|---|---|
| RTL | Register-transfer level |
| SVA | SystemVerilog Assertions |
| SAT | Boolean satisfiability |
| T-IR | Q3AFormal transition-system intermediate representation |

