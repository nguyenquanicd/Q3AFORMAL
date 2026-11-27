# Q3AFormal Proof Cache

The Phase 0 proof cache stores only checker-accepted DRAT artifacts for supported scalar, same-sample `##0` sequence, overlapped-implication, or restricted non-overlapped assertion k-induction queries. It is optional and is enabled with `--cache-dir` on `--prove-inductive`.

```powershell
& $q3a --prove-inductive .\prototype\known-pass-combinational.q3a `
    --property p_y_implies_a `
    --output-prefix .\evidence\trial\first `
    --cache-dir .\evidence\proof-cache
```

The first run creates per-obligation entries under the cache directory. A later run regenerates the lowered model and exact CNF, computes the content identity, and reports `Q3A_INDUCTION_CACHE <base|step> HIT` only after the current DRAT checker validates the cached artifact against those exact bytes.

Each key binds source-set and canonical-model hashes, semantic profile, T-IR schema, exact query/CNF hash, Q3A build ID, checker ID/fingerprint/schema, property, induction depth, obligation kind, algorithm, and SAT/proof resource options. A changed identity produces a miss. An entry with mismatched files, hashes, metadata, or a rejected proof is never trusted; a fresh proof search runs, and a newly checked artifact can replace the rejected entry while retaining the rejected directory with an `.invalid-*` suffix.

Cache lookup hashes the current and saved CNF and the saved proof in bounded blocks. It checks the cached CNF and proof through the same Windows handles used to hash them, with writes denied, and copies the accepted proof to per-run staging. Cache storage checks staged copies before publishing by directory rename. Neither path loads the complete CNF or proof text. The checker's live clause database remains in memory.

Failure to write the cache does not change a freshly checked proof result. The cache does not store SAT witnesses, `UNKNOWN` results, BMC outcomes, or query search state. It does not replace result bundles, validate RTL-to-T-IR translation, or extend the supported RTL/SVA profile. The key is content-addressed and includes the whole Q3A build identity, so a tool rebuild intentionally invalidates earlier entries.

Run the cache unit and CLI integration checks with:

```powershell
.\prototype\tests\test_proof_cache.ps1
```

