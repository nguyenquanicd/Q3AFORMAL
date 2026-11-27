# T017 SVA-004 Bounded Cover Conformance Evidence

**Date:** 2026-11-20  
**Matrix row:** SVA-004, scalar/sequence/implication `cover property`  
**Vector:** SM-051, `bmc_cover_implication.sv`  
**Regressions:** `test_sequence_bmc_bitblast.ps1` and `test_bmc_cover_implication.ps1`

## Results

Both regressions passed on 2026-11-20. The independent sequence/cover oracle compares the encoded cover queries with trace evaluation over the finite assignment sets for scalar, sequence, repeated, overlapped-implication, and non-overlapped-implication goals (900 assignments in the reviewed corpus). Source-level queries produce replay-validated witnesses for scalar overlapped, scalar non-overlapped, and sequence-antecedent covers. A non-overlapped cover with an insufficient horizon returns `UNKNOWN` and `NOT_FOUND_WITHIN_BOUND` with an incomplete bounded scope; no unreachability claim is made.

SVA-004 is **Supported for the tested bounded scalar, sequence, and linear-implication cover subset**. The sequence-oracle regression now links `source/lowering/horizon.cpp`, which defines T-IR horizon and history-guard helpers needed by the transition encoder.

## Limits

The implementation does not report full IEEE property coverage counters or separate vacuous-success accounting. A bounded cover miss is not `UNREACHABLE`; multi-clock and other unsupported SVA forms remain outside the profile. T016/T017 remain open for the rest of source-to-model semantics.
