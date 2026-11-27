# Q3AFormal Phase 0 Benchmark Threshold Proposal

**Status:** Approved by the owner on 2026-11-21. The eight jobs and limits are frozen in [the approved manifest](../../prototype/benchmark/phase0-jobs.approved.json).
**Host memory input:** 16 GB installed RAM, user-reported on 2026-11-20. This is a sourced label, not a measured byte count. OS-visible physical memory is recorded separately by the runner.

## Purpose

This proposal supplies initial stop and evaluation limits for the existing small Phase 0 jobs. The limits are intended to catch hangs or unexpected resource growth in the prototype. They are not production-scale claims and do not establish suitability for large designs.

## Proposed per-job limits

| Job | Expected outcome | Wall-clock timeout | Peak working-set evaluation limit | Rationale |
|---|---|---:|---:|---|
| B-01 counter induction | `PROVEN` | 120 s | 4 GiB | Includes transition encoding, base/step solving, and independent proof checking. |
| B-02 mutated counter witness | `BOUNDED_FAIL` | 30 s | 4 GiB | One-transition counterexample with replay. |
| B-03 `casez` induction | `PROVEN` | 120 s | 4 GiB | Includes proof generation and independent checking for the decoder invariant. |
| B-04 one-entry handshake cover | `COVERED` | 30 s | 4 GiB | One-transition cover search and witness replay. |
| B-05a through B-05d unsupported-input diagnostics | source-located rejection | 10 s each | 1 GiB each | Parse/lowering-only jobs; no SAT query should start. |

## Measurement semantics and caveats

- A timeout is a stop limit: the runner terminates the job and records `TIMEOUT`; that result is inconclusive and cannot count as a formal pass.
- The working-set value is a post-run acceptance threshold. The current runner records the process peak working set but does not enforce a hard memory cap. A run above the proposed value is a resource-limit miss, not a correctness failure.
- The runner samples working set periodically and also reads the process peak value on exit. Confirm measurement behavior on the selected Windows host before using it to compare builds.
- These limits apply to the current small corpus and the 16 GB installed-memory host profile only. Keep the host profile's CPU model, core counts, Windows build, compiler version, and build configuration in every measured run.
- The current CLI prototype has no interactive trace-navigation benchmark. Defer GUI trace latency thresholds until an implemented GUI and representative trace corpus exist.
- Do not apply a performance pass/fail judgment until the owner approves this proposal and the exact benchmark properties. Raw diagnostic measurements, if separately authorized, must remain clearly labeled as unassessed.

## Approval record

| Decision | State |
|---|---|
| Installed-memory label | User supplied: 16 GB |
| B-01 through B-05 property and expected-result review | Approved on 2026-11-21 |
| Proposed wall-clock limits | Approved on 2026-11-21 |
| Proposed peak working-set limits | Approved on 2026-11-21 |
| Official Phase 0 measurement | Authorized on the current Windows host |

The source checker was rebuilt from all translation units before measurement with GNU C++ 16.2.0, C++17 and `-O2`. B-01/B-03 use default induction depth 1. B-02/B-04 use one bounded transition. The solver uses the defaults of the frozen build. The runner records the host before launching the jobs.

| Frozen artifact | SHA-256 |
|---|---|
| Approved jobs manifest | `e21e127eb357f4f1b2b47c18cd2db52d5484eac7185d09259cb4b65c060a2503` |
| Source checker | `00679ebe096fcc1b1f3ac2ea4680b53082a39859fd9f97a0510f09e372967a4c` |

