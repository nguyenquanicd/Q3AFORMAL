# Phase 1 Native Block Benchmark Thresholds

**Status** The owner approved the five native block-level job limits on 2026-11-25 at 04:11:34 UTC+07:00. The [approved limit record](../../prototype/benchmark/phase1-block-limits.approved.json) preserves the exact workload, limits, and approval time. These limits cover the five existing block jobs on the recorded Windows x64 host with an AMD Ryzen 7 7445HS and owner-reported 16 GB installed memory. The executable digest is recorded on each measurement. The workload and all four project and source digests are pinned in the [limit record](../../prototype/benchmark/phase1-block-limits.proposed.json).

The pilot maxima below come from six runs of the same frozen job manifest, including two runs on the current Windows candidate. The comparison uses elapsed wall time and sampled process working set. The Phase 1 runner's existing watchdog stays separate from these acceptance comparisons. The proposed margins allow for repeated small-block regression runs under variable workstation load. [Candidate run 1](../../evidence/benchmark/runs/phase1-batch-candidate-pilot-1-2026-11-24/measurements.csv) · [Candidate run 2](../../evidence/benchmark/runs/phase1-batch-candidate-pilot-2-2026-11-24/measurements.csv) · [Previous slowest pilot](../../evidence/benchmark/runs/phase1-block-pilot-sampled-2026-11-24/measurements.csv)

| Job | Maximum pilot wall time | Maximum sampled working set | Proposed wall time limit | Proposed working set limit |
|---|---:|---:|---:|---:|
| P1-01 Elastic pipeline induction | 1.629 s | 9.12 MiB | 15 s | 128 MiB |
| P1-02 Elastic pipeline stall mutation | 3.634 s | 29.62 MiB | 30 s | 256 MiB |
| P1-03 Elastic pipeline reset and transfer | 0.724 s | 11.73 MiB | 15 s | 128 MiB |
| P1-04 Arbiter registered-grant proof | 0.337 s | 8.20 MiB | 15 s | 128 MiB |
| P1-05 Elastic pipeline 24-transition check | 2.017 s | 16.07 MiB | 15 s | 128 MiB |

The stall mutation gets the larger allowance because it solves a longer witness prefix and exports replay evidence. Each job must also match the expected formal result and pass its proof or bundle checks. The comparison script reruns those checks before evaluating the resource measurements. Working set measures resident process memory. Q3A's process-private memory policy continues to operate independently.

For acceptance under Q3AF-AC-17, record the owner's approval and its date and time, then capture a fresh run. The comparison script labels a proposed-limit comparison as a preview. When given an approved record it checks that the run started after the recorded approval. [Comparison script](../../prototype/benchmark/compare_phase1_block_limits.ps1)

The post-approval run passed all five native jobs on the exact packaged build. The acceptance verifier matched the workload, host, approval chronology, and functional evidence. [Approved comparison](../../evidence/benchmark/runs/phase1-approved-native-block-2026-11-25/approved-limit-verdict.json)

The browser trace-navigation pilot used a simulated Document Object Model. A browser interaction threshold requires evidence from the actual browser and remains outside this proposal.
