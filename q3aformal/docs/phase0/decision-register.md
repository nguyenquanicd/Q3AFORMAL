# Q3AFormal Phase 0 Decision Register

**Decision date:** 2026-11-15  
**Gate A:** Approved for Phase 0 work after the owner selected the balanced RTL/SVA profile  
**Gate B:** Owner approved GO on 2026-11-24 for the Phase 1 block-level minimum viable product (MVP), retaining C++17 and Deletion Resolution Asymmetric Tautology (DRAT).  
**Scope:** Phase 0 approval and Phase 1 starting decisions.

| ID | Decision | Status | Basis / limit |
|---|---|---|---|
| OD-01 | Use profile Q3A-P0-R0.9.1, defined by §15 of Q3AFORMAL_SPECIFICATION.md revision 0.10 and the versioned conformance matrix. | Approved by owner | Includes case/casez, positive-count bounded consecutive repetition, guarded $past, and exact-width connected ports. Exact zero-count/zero-minimum repetition is rejected by owner selection. Excludes multi-clock, disable iff, liveness/fairness, and unsupported forms. |
| OD-02 | Use a two-valued model with unconstrained initial state and synchronous reset included in every transition frame. | Approved by owner | Reset does not constrain S[0]; startup reset is an explicit assumption. |
| OD-03 | Use C++17 and Windows x64 as the Phase 0 development target. | Selected for Phase 0 | C++17 was the proposed candidate. Windows x64 follows the user's working environment. This is not a portability claim; record exact compiler and host hardware for benchmarks. |
| OD-04 | Keep the product's no-third-party formal/runtime dependency boundary. | Approved approach | Q3A owns the frontend, solver, proof/checking, replay, and trace behavior. |
| OD-05 | Evaluate DRAT as the first SAT proof-artifact candidate with a structurally separate checker. | Approved evaluation approach | Final proof-artifact format remains open until evidence review at Gate B. |
| OD-06 | Use independently authored, small RTL/SVA benchmark designs with known outcomes. | Approved approach | Do not use external tools as proof oracles. Record source and license provenance. |
| OD-07 | Approve numeric runtime and memory thresholds before the first benchmark measurement. | Approved on 2026-11-21 | See the [approval record](benchmark-threshold-proposal.md) and [measured results](../../evidence/benchmark/benchmark-report.md). |
| OD-08 | Gate A approval for Phase 0 planning and prototype work. | Approved by owner | Owner approved the recommendations and selected the balanced profile on 2026-11-15. Gate B remains required before Phase 1. |
| OD-10 | Close Phase 0 and proceed to the Phase 1 block-level MVP with C++17 and DRAT. | Owner GO on 2026-11-24 | T033. See the [accepted build, eight benchmark results, and four bundle revalidations](../../evidence/phase0-go-no-go.md). |

## Approved Balanced Profile Summary

### RTL

- One module hierarchy, module instances, parameters/localparams. Phase 0 requires exact bit-width matches on connected ports; implicit port extension/truncation is rejected.
- Packed integral values with two-valued data semantics.
- Continuous assignment; combinational always_comb; positive-edge always_ff with nonblocking sequential updates.
- if/else, case, casez, and static generate if/for with constant conditions.
- Basic arithmetic, logical/bitwise operations, comparisons, concatenation, constant selects, and constant left/right shifts.
- Synchronous reset is part of every transition frame.

### SVA

- One bound positive-edge clock.
- Concurrent assert, assume, and cover properties.
- |->, |=>, constant ##N, and bounded consecutive repetition. Exact and ranged repetition bounds must be positive; zero-count/zero-minimum forms are rejected by owner selection.
- $past(expression) and $past(expression, N) with positive constant delay and model-generated history-valid guard.
- Exclude disable iff, multi-clock properties, liveness/fairness, $stable/$rose/$fell/$changed, goto/nonconsecutive repetition, and unlisted forms.

The normative subset, exact operator rules, strict port-width rule, and diagnostics are in §15 of revision 0.10 and profile Q3A-P0-R0.9.1.

| OD-09 | Exclude exact zero-count and zero-minimum bounded repetition from Phase 0 | Approved by owner | Keeps empty-sequence semantics outside the balanced Phase 0 contract; exact and ranged repetition use positive bounds. |

## Phase 0 Benchmark Set

All designs are original Q3A-authored RTL/SVA examples; expected results are reviewed manually and represented in the source-to-model corpus.

1. **counter4_pass:** 4-bit modulo counter with reset; check a one-step transition invariant using a checked induction/invariant proof.
2. **counter4_fail:** Mutated wrap behavior; a separate property must fail with a short replay-validated witness.
3. **casez_decode:** Small packed-input decoder with static wildcard patterns; check ordered/exclusive output behavior.
4. **handshake1_entry:** One-entry valid/ready buffer with bounded protocol properties and selected $past use guarded by history-valid state.
5. **unsupported_syntax:** Small inputs containing multi-clock, disable iff, X-valued data, or unlisted SVA operators; each must be rejected before proof.

The benchmark plan is frozen at the design-category level. Before performance measurement, record exact source hashes, expected outcomes, hardware/compiler configuration, and numeric time/memory limits in benchmark-plan.md.








