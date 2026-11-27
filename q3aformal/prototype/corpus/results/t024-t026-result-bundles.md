# T024–T026 Result-Bundle Implementation Evidence

**Date:** 2026-11-16  
**Feature:** Q3AFormal Phase 0  
**Bundle schema:** `Q3A-RUN-BUNDLE-1`

## 2026-11-21 staged streaming

The writer now sends bounded query conjunctive normal form (CNF) and replay trace JSON directly to the staging directory. Waveform copies and file hashes use 64 KiB buffers. The manifest tracks metadata while staging, and the final directory is published after its artifacts and digest are written.

`test_result_bundle.ps1` passed for bounded failure, bounded pass, inconsistent assumptions, and checked induction. Independent SHA-256 and size checks matched the executable and every indexed artifact. The regression also compared both bundled waveforms with their exported bytes and revalidated fresh bounded failure, bounded pass, and induction bundles.

A separate 1,024-transition check produced a 597,517-byte CNF and a 71,780-byte trace. PowerShell `Get-FileHash` matched both manifest digests, and bundle reopening independently replayed all 1,025 frames. The adaptive-memory stop regression passed on the same build.

## 2026-11-21 streaming verification

The verifier now hashes each artifact in 64 KiB blocks without retaining passive file contents. When later verifying an active proof or replay input, it checks the bytes again against the indexed digest. The reopening regression generated a proof using the current checker, preserved historical handling of an archived proof with a different checker fingerprint, and detected a same-length change after the first 64 KiB of a 144,000-byte attachment.

An engineering comparison on Windows reopened the same replayable bundle with an indexed 128 MiB synthetic attachment. Three alternating runs per build returned `REVALIDATED`. The process private memory size was sampled through PowerShell process counters with a 5 ms wait between samples.

| Build | Executable SHA-256 | Highest sampled private memory per run (MiB) |
|---|---|---|
| Previous reader | `077d1c9c26be2c718f53bd8b35db676b62f8ca462707b12dcdaf8b74ce03719b` | 257.66, 257.65, 257.66 |
| Chunked reader | `c562f10db7046c3ddabdfcd21aef873f71b78497e2ca9fdc85047d5e33902df0` | 1.18, 1.20, 1.19 |

This measurement covers the integrity checking of passive bundle attachments. Active proof checking and replay still allocate memory for their own inputs and working state. Peak-memory comparisons for large active designs and streamed induction proof generation remain open.

## Implemented

- `--bundle-dir <new-directory>` writes the exact project manifest and RTL snapshot, canonical T-IR, query CNF, per-property summary and available witness/proof evidence. The bundle includes source/model/query/artifact hashes, a manifest sidecar hash, build/component/checker identity, assumptions, reset policy, resource-limit semantics, vacuity and boundary status. New bundles are published atomically and existing output directories are rejected.
- BMC normal results, contradictory model/assumption results, and feasibility `UNKNOWN` results preserve their exact query evidence. The contradictory-assumption fixture is `prototype/bmc-conflict.q3a`.
- `--verify-bundle <directory>` checks the manifest sidecar, relative paths, file types, listed artifact byte counts/hashes, project and RTL snapshots, canonical T-IR, and query-to-CNF identity. It rejects symbolic links, traversal paths, and modified evidence.
- Matching DRAT artifacts are rechecked only when checker ID, schema, and recorded checker-component source fingerprint match the executable. For BMC bundles with a replay trace, the verifier reconstructs supported serialized T-IR and independently checks the saved trace against its equations, assumptions, and property. For no-witness assertion `BOUNDED_PASS` and cover-miss results, it can regenerate byte-identical CNF and rerun the UNSAT query when the SAT bit-blaster fingerprint matches. It reports the applicable `REVALIDATED` scope; none of these checks certifies source translation. Cover misses remain bounded, not `UNREACHABLE`.

## Durable examples

- Known pass: [`evidence/known-pass/run-bundle-2026-11-16-v2/`](../../../evidence/known-pass/run-bundle-2026-11-16-v2/). `PROVEN`, scope `GENERATED_TIR_MODEL`; both base and step DRAT files passed a second check from the saved bundle. Manifest SHA-256: `f0954b2c19dc036eaea762a2d6f74063a7fdf6f55268784009c688726cf2aab7`.
- Known fail: [`evidence/known-fail/run-bundle-2026-11-16-v2/`](../../../evidence/known-fail/run-bundle-2026-11-16-v2/). `BOUNDED_FAIL`, replay-validated witness, `NONVACUOUS`, and incomplete later boundary obligations. Reopen replays the witness against the bundled T-IR. Manifest SHA-256: `74d93d14b1684426f6979e6d49d7c61c9dfb756faeebefba38aeee2ef73a527d`.

## Validation

- `prototype/tests/test_result_bundle.ps1`: BMC bounded-fail, bounded-pass, contradictory-assumption, and k-induction bundles; checks manifest/model/source/query/artifact hashes and overwrite refusal.
- `prototype/tests/test_bundle_reopen.ps1`: reopens the saved known-pass and known-fail bundles, rechecks compatible DRAT proofs, replays assertion, guarded-`$past`, and cover witnesses, reexecutes compatible no-witness bounded queries, preserves `HISTORIC` for an incompatible SAT component fingerprint, rejects a hash-consistent but semantically false trace, changed model bytes, and parent-directory traversal, and confirms a mismatched checker fingerprint is not used for proof revalidation.
- All 19 PowerShell integration scripts passed together. After tightening the checker-source-fingerprint compatibility check, `test_bundle_reopen.ps1` was rebuilt and passed again.

## Remaining boundary

Bundle reopening replays saved BMC traces against reconstructed supported T-IR, reexecutes compatible no-witness bounded-pass/cover-miss queries, and rechecks compatible induction proofs. It does not independently validate source-to-T-IR translation. Cover misses remain `NOT_FOUND_WITHIN_BOUND`; they do not imply unreachability. T027 implements optional checked k-induction proof caching for supported scalar and one-cycle overlapped-implication properties; broader source/SVA conformance (T016/T017) and the remaining Phase 0 proof/replay work are still open.

## 2026-11-18 saved BMC trace replay increment

At this result-bundle milestone, `--verify-bundle` reconstructed supported `Q3A-TIR-0.3` fields from the hash-verified canonical model, parsed saved `Q3A-TRACE-JSON-1` frames, checked result/query/property linkage and the recorded bound, then independently replayed the witness. The known-fail bundle reported `Q3A_BUNDLE_TRACE_REPLAY VALIDATED` with scope `REPLAYED_BMC_WITNESS_FOR_SERIALIZED_TIR`. Regression covered scalar implication failure, guarded-`$past` failure, and bounded sequence cover traces, and changed a signal value while updating its trace hash and manifest sidecar to confirm replay rejected the false witness. Current source lowering emits T-IR 0.4; bundle compatibility and the history-guard change are documented in [the T-IR 0.4 report](t016-sva-history-guard-alignment-2026-11-19.md). Bundle replay still does not verify RTL-to-T-IR translation.

## 2026-11-19 bounded-query revalidation increment

For no-witness assertion `BOUNDED_PASS` and cover-miss bundles, `--verify-bundle` now reconstructs the bounded query from saved T-IR, confirms the regenerated DIMACS bytes exactly match the saved CNF, checks that assumptions remain feasible, and reruns the UNSAT query when the SAT component fingerprint is compatible. Cover misses retain the bounded status `NOT_FOUND_WITHIN_BOUND`. Regression also changes the SAT component fingerprint while preserving manifest integrity and confirms the bundle remains `HISTORIC` with no query-revalidation claim. The result proves only the saved T-IR query, not RTL-to-T-IR translation.
