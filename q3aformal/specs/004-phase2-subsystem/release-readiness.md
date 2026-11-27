# Phase 2 release acceptance

The Windows x64 revision 16 archive passed the Phase 2 functional and collector preflights for specification §16.3 and the approved Phase 0 and Phase 1 compatibility runs. Each result applies to its recorded build and profile. [Product specification](../../../Q3AFORMAL_SPECIFICATION.md#16-development-roadmap) · [Phase 0 decision](../../evidence/phase0-go-no-go.md) · [Phase 1 acceptance](../003-phase1-block-mvp/release-acceptance.md) · [Revision 16 archive](../../dist/q3aformal-windows-x64-development-preview-r16.zip)

| Requirement | Evidence | Disposition |
| --- | --- | --- |
| Sound proof composition | The functional preflight checks a whole-subsystem result and nine checked composition obligations for the frozen transport design. | Accepted after three monitored composition runs and source proof revalidation. |
| Multi-clock semantics | The development profile checks free positive-edge masks with joint updates from one pre-state. The focused suite checks source-bound certificates, replay, and native Windows cursor navigation. | Approved free positive-edge masks, idle steps, local property samples and the documented fairness boundary. |
| Exact memory | The development profile checks one single-clock unpacked array and its same-clock scalar controls. It validates both address ranges and the selected property before publishing the proof group. | Approved read-old collision policy, symbolic uninitialized cells, supported source forms and checked address limits. |
| Batch scheduling, caching, and resumption | Functional preflight covers equivalent results with one and two workers plus source revalidation. The product regression covers independent checkpoint and cache paths. | Accepted after the serial and parallel workloads met the approved limits. |
| Sequential equivalence | The transport preflight checks the qualified matched-initial-state plan and reopens its evidence. | Accepted after three monitored equivalence runs and reopened certificates. |
| Dependency boundary | Archive member hashes and the imported Windows runtime libraries are verified on the extracted tools. | Verified in the revision 16 release acceptance. |

The frozen timing proposal has five workloads. Each has three repetitions and a 30-second limit. Four workloads use a 512 MiB peak process-tree working-set limit. Parallel batch uses 768 MiB. The owner approved these limits for revision 16 on 2026-11-27. All 15 post-approval runs met both limits and passed source revalidation. The independent audit recomputed the saved verdict and reopened the retained proofs. [Benchmark proposal](../../prototype/benchmark/phase2-subsystem-limits.proposed.json) · [Frozen workload hashes](../../prototype/benchmark/phase2-subsystem-workloads.json) · [Owner decisions](../../evidence/r16/owner-decisions.json) · [Approved limits](../../prototype/benchmark/phase2-subsystem-limits.approved.json) · [Measured verdict](../../evidence/r16/phase2-acceptance/verdict.json)

The collector preflights used the exact executables from the revision 14 and revision 15 Windows packages and verified all five functional workloads on each. They exercised Windows process-tree sampling and watchdog behavior. The collector rejected unapproved limits, preapproval data, missing or duplicate repetitions, a timeout, missing working-set samples, and altered proof bytes with both original and refreshed artifact digests. This was preflight evidence before the approved revision 16 capture. [Revision 14 collector qualification](../../evidence/r14/phase2-collector-preflight/qualification.json) · [Revision 15 collector qualification](../../evidence/r15/phase2-collector-preflight/qualification.json)

The standalone checker extracted from revision 15 accepted all 51 retained Deletion Resolution Asymmetric Tautology (DRAT) proof records, including nine composition obligations and six equivalence certificate records. The total counts archived and direct copies separately. It rejected six controls that paired a proof with a different query. The existing source-backed preflight supplies source and query revalidation for these workloads. [Standalone checker results](../../evidence/r15/phase2-standalone-proof-preflight.json)

Revision 16 fixes Unicode command-line paths in both Windows executables and has passed the approved Phase 0 and Phase 1 compatibility checks. [Revision 16 compatibility qualification](../../evidence/r16/qualification.json) Its extracted executable passed the same five subsystem functional workloads and all six focused suites. The packaged standalone checker accepted 51 saved proof records and rejected six query substitutions. The collector identified all five source-revalidated workloads without recording acceptance timings. Two workers also completed a relocated subsystem proof from paths containing spaces and Vietnamese characters. A resume command reopened all four source-checked bundles. [Unicode worker evidence](../../evidence/r16/unicode-parallel-checkpoint.json) [Runtime qualification](../../evidence/r16/portable-install-qualification.json) · [Focused suites](../../evidence/r16/phase2-focused/qualification.json) · [Standalone checker](../../evidence/r16/phase2-standalone-proof-preflight.json) · [Collector](../../evidence/r16/phase2-collector-preflight/qualification.json)

## Revision 15 owner review

The package SHA-256 is `2f6b602c1907002db28ecd69fdb207306397d900fedff5606ee4a6d398a1f0c2`. The historical proposal below informed the revision 16 owner approval. Earlier OD-07 approvals cover the Phase 0 benchmark, Phase 1 block benchmark, and Phase 1 graphical viewer benchmark.

| Decision | Scope submitted for review |
| --- | --- |
| OD-07 subsystem limits | Five workloads, three fresh runs each. Each run must pass source revalidation and finish within 30 seconds. Peak process-tree working set is limited to 512 MiB per run, with 768 MiB for parallel batch. The proposal SHA-256 is `1f93c41f0489f0bb25d612edd7fd8ffbc101f46655e0e68acdd64ef8c1881f6b`. [Exact proposal](../../prototype/benchmark/phase2-subsystem-limits.proposed.json) |
| Exact memory | Single-clock guarded array with old data on same-address read and write, hold behavior when access is disabled, and symbolic two-valued initial cells. Adopt the source restrictions, checked address ranges, and allocation limits in the contract. [Memory contract](memory-and-equivalence-review.md) |
| Multi-clock scheduling | Free positive-edge masks allow idle steps and simultaneous edges. Each domain reads the common pre-state and samples properties on its own edges. The model assumes no fairness or frequency relationship. [Scheduling contract](multi-clock-scheduling-review.md) |

The owner adopted the recorded exact-memory and free-event-mask contracts for revision 16. The approval binds both contract digests to the accepted archive. The post-approval capture retains all 15 runs and their evidence. [Owner decisions](../../evidence/r16/owner-decisions.json) · [Raw benchmark capture](../../evidence/r16/phase2-acceptance/capture.json) · [Focused evidence](../../evidence/r16/phase2-focused/qualification.json) · [Phase 3 scope decision](../005-phase3-profile-expansion/release-readiness.md#revision-15-owner-review)

## Accepted subsystem qualification

Revision 16 satisfies the Phase 2 requirements for the adopted memory and scheduling profiles, proof composition, property batching and checkpoint resumption, and matched-initial-state equivalence. All three repetitions of each workload met the 30-second limit and passed source revalidation. [Final release acceptance](../../evidence/r16/release-acceptance.json) · [Benchmark verdict](../../evidence/r16/phase2-acceptance/verdict.json)

| Workload | Passed | Longest run | Peak working set | Memory limit |
| --- | ---: | ---: | ---: | ---: |
| monolithic | 3/3 | 0.319 s | 19.17 MiB | 512 MiB |
| composed | 3/3 | 0.544 s | 17.95 MiB | 512 MiB |
| sequential-batch | 3/3 | 0.858 s | 19.17 MiB | 512 MiB |
| parallel-batch | 3/3 | 0.847 s | 55.62 MiB | 768 MiB |
| equivalence | 3/3 | 0.736 s | 18.63 MiB | 512 MiB |

On a fixed single-domain edge mask, each edge enable evaluates to one. The common lowering then gives the same reset and next-state assignments, and history and sequence monitors advance on every sample. Initial monitor state is zero-filled in both models. The component miter checked both mismatch polarities for 56 state, output, assertion, assumption and cover observations over seven samples, with arbitrary inputs and equal initial RTL state. The same suite independently checked 27 proof obligations for range, memory and clock-local properties. [Component evidence](../../evidence/r16/phase2-transition-proof/qualification.json)

## Historical evidence

Revision 14 passed all 118 repository suites on its first run, 38 integrated profile suites, six application suites, eight Phase 0 cases, four source-backed bundle checks, five Phase 1 block workloads, and six visible Windows GUI runs. The revision 14 Phase 2 workload evidence is a functional preflight. [Revision 14 qualification](../../evidence/r14/qualification.json) · [Revision 14 functional preflight](../../evidence/r14/phase2-preflight/qualification.json)

- [Package and Windows runtime audit](../../evidence/r14/package-construction.json)
- [Extracted profile and subsystem preflight qualification](../../evidence/r14/profile-check/qualification.json)
- [Extracted same-clock scalar memory qualification](../../evidence/r4/focused/scalar-memory/qualification.json)
- [Atomic group failure-injection tests](../../evidence/p2-memory-group-atomic-component-final/qualification.json)
- [Memory semantics and range proof](memory-and-equivalence-review.md)
- [Free-event-mask semantics](multi-clock-scheduling-review.md)

The revision 15 executable reopened checked parallel results, resumed checkpoints, and revalidated the source-derived composition proof. Its exact-memory tests also verified refusal before an oversized allocation, four classes of saved range witnesses and native replay of invalid read, simultaneous access and provisional witnesses. The focused suite ledger binds all six test results to the executable in the Windows archive. [Revision 15 focused evidence](../../evidence/r15/phase2-focused/qualification.json)

The Phase 3 preview includes guarded sampled values, bit-vector functions, parameter sweeps, paired equivalence traces, Advanced eXtensible Interface 4 Lite (AXI4-Lite) read and write applications, and named strong eventual-response assertions with state justice. The qualified liveness scope uses a single sampled clock and explicit finite graph enumeration. Revision 14 also includes finite four-state sequence composition, reusable named properties and saved counterexample replay. Phase 3 scope review and replay performance evidence are tracked in its release record. [Phase 3 readiness](../005-phase3-profile-expansion/release-readiness.md) · [Four-state profile](../005-phase3-profile-expansion/four-state-expressions.md) · [Liveness scope](../005-phase3-profile-expansion/fair-cycle-liveness.md)
