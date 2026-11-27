# Q3AFormal Phase 2 Batch Scheduling and Resume Review

This proposal covers optional property-level concurrency and resumable work under Q3AF-FR-032 and Q3AF-FR-033. Phase 1 already runs one job at a time, retains the declared plan and job order, and reports interruptions. The proposed batch format preserves that default and allows existing plans to run unchanged.

## Resource policy

- Reserve a fixed slot for the coordinator, source snapshot, report publication and admission accounting. Give each admitted worker a fixed memory reservation before it starts. The sum of coordinator and active worker reservations must stay within the user's configured batch budget.
- Consult a host memory-pressure adapter before each admission. A lower available-memory observation postpones new work. A falling estimate never changes an active job's engine, depth, clauses or property semantics. If a shortage interrupts a worker, record its existing non-conclusive status and release the reservation after the worker exits.
- Start with extra workers only when the user selects concurrency and an enforceable process memory policy is available. Compare a declared logical reservation with the observed process memory metric separately. Phase 1 benchmark working-set observations remain a separate form of evidence from process-private memory enforcement.
- Treat disk-backed immutable source inputs, checked artifacts, and streaming trace chunks as candidates for reducing memory use. Check remaining disk capacity, bound staging, and preserve original evidence on publication failure. Keep SAT solver state in memory until there is a separately validated design for spilling it.

The compact solver stores two watched positions per clause and reads its literals from the existing arena. On the 300-transition bounded model checking cover, sampled peak private commit fell from 201.94 MiB to 172.13 MiB at the same 256 MiB limit. The new build reached and replayed the witness at 192 MiB. The previous build returned `UNKNOWN` at that limit. The checked transition model, Conjunctive Normal Form (CNF) query and indexed witness had identical digests. The new build also revalidated the previous cover bundle and an archived proof from source. These measurements apply to the named fixture. [Measurement and revalidation evidence](../../evidence/p3-compact-sat-watch/qualification.json)

Before the first conflict, the next decision starts at the lowest variable that can still be unassigned. After a conflict, selection uses the existing activity scores and variable order. On the archived 300-transition formula, the component median over three solves fell from 693.53 ms to 319.92 ms. The assignment, 1,204 decisions and 600,873 propagations matched. In one integrated run per build at 192 MiB, the elapsed time including query construction and witness replay fell from 1,651.62 ms to 997.67 ms. The formula and indexed witness retained their digests. The conflict and incremental oracles passed 5,400 queries each, and the standalone checker accepted 1,233 proofs. [Decision selection evidence](../../evidence/p3-sat-decision-cursor/qualification.json)

## Safe resume

A versioned batch identity binds the ordered inputs and effective parameter settings, plan bytes, model semantics, build and checker identity. Each completed job publishes a terminal result with an artifact manifest only after its evidence has been checked. Publication uses a job-local staging directory and a final commit record. A staged-only record after interruption is pending on resume. A complete record is reusable only if its identity and evidence verify against the resolved job.

Report records in the plan's declared order. Concurrency can change completion order and elapsed timings. Reuse the committed proof or witness without changing its recorded provenance. A previous resource-limited or timed-out result is a recorded attempt. Any retry leaves that evidence intact and receives a new attempt record. A mismatched input identity needs a new batch run.

## Evidence required before enabling concurrency

| Trial | Expected outcome |
| --- | --- |
| Run an existing version 1 or 2 plan | Default sequential behavior, result schema and issue reporting remain compatible. |
| Reorder worker completion and compare with a sequential run | Same ordered property outcomes and valid proofs or witnesses under equal query limits. |
| Lower available memory during admission | New workers wait or report a resource limit. No implicit changes to bounds or property semantics. |
| Interrupt before and after each publication step | Only source-matched committed evidence can be reused. In-flight jobs return to the pending queue. |
| Modify an active header, engine limit, or archived artifact | Reject reuse for the mismatched identity. Retain original evidence. |
| Exhaust disk space or deny replacement | Surface the storage failure. Keep valid previously published results intact. |

The first implementation should qualify serial resume on the existing batch entry point before adding extra workers. Measure benefit and peak memory on a frozen subsystem workload with separately approved limits.

## Windows worker memory control

The first Windows worker should start suspended, join a dedicated Job Object, and resume only after the coordinator installs its memory limits. Bound committed memory for both the worker and its process tree. If assignment fails under a host-managed process policy, stop that worker before it runs and report the admission failure. The coordinator retains its logical reservation until the worker exits. [Process creation flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags) · [Job assignment](https://learn.microsoft.com/en-us/windows/win32/api/jobapi2/nf-jobapi2-assignprocesstojobobject) · [Job memory limits](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_extended_limit_information)

A C++17 host probe applied a 64 MiB committed-memory limit before starting a child. The worker received an allocation failure while committing 8 MiB chunks. The job's recorded peak was 61,108,224 bytes and its process peak was 59,834,368 bytes. This qualifies the native host mechanism. Product-level admission, multiple workers, proof integrity, interruption and recovery remain separate checks. [Probe source](windows_batch_memory_probe.cpp) · [Host evidence](../../evidence/phase2-native-batch-memory/host.json)

## Serial checkpoint interface

```powershell
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --checkpoint
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --resume
```

Use the same batch root, executable build, project manifest bytes, resolved sources and plan bytes for both calls. A blocked or interrupted proof can be retried on resume. Use a new batch root after changing job options or design sources. Existing non-checkpoint runs keep their original output layout.

The checkpoint root contains `checkpoint.identity`, an exclusive writer lock, and numbered `attempt-N` directories. Each attempt retains its job-local records and writes its own `batch.json` if it reaches reporting. Recovering prior jobs does not depend on that aggregate report. A job directory without an atomic `checkpoint.commit` is eligible to run again. A committed result is inspected against the exact project and plan, then its source-backed proof or witness is revalidated before the new report references it. The report preserves plan order and marks reused jobs. A failed recheck reports an error and retains earlier attempts.

Resume works at the job boundary. It restarts the search for pending and non-conclusive jobs. A timeout or a memory-limit result remains part of the prior attempt. Bounded passes without independently reusable conclusive evidence run again. The current format stores original artifact paths, so keep the checkpoint root at the same absolute path. Serial mode runs one proof job at a time.

## Serial checkpoint qualification

The staged Windows executable recovered committed PDR evidence after deliberate termination of a live batch before its aggregate report was written. The suite reproduced proof and witness results for PDR, bounded model checking and k-induction. It also checked inactive or missing commit markers, a prior bounded pass, recovery across multiple attempts, a changed manifest source, a changed plan, an active writer lock, a damaged proof and a property substitution with a refreshed digest. The existing version 1 and 2 batch behavior and the strict source-required reopening suite passed on the same executable. [Checkpoint regression](test_batch_checkpoint.ps1) · [Qualification](../../evidence/r-p2-resume/qualification.json)

This is Phase 2 staging evidence. The qualified Phase 1 Windows archive remains the current packaged baseline.

## Optional parallel workers

```powershell
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --checkpoint --workers 2
.\q3aformal-sourcecheck.exe prove-batch design.q3a --plan jobs.q3b --output-dir proof-results --resume --workers 2
```

The default uses one worker and preserves the serial format. Requests for two through eight workers use checkpoint mode. The coordinator reserves the larger of 64 MiB or one quarter of the plan budget. It divides the remaining whole mebibytes equally among the requested workers, with at least 32 MiB for each. It consults available physical memory before admission, retains a reservation until the worker exits, and bounds the committed memory of each worker process tree through its Windows Job Object. The coordinator applies its reservation when loading source and materializing reports.

Each worker loads the project and checks its resolved source and manifest identities against the coordinator's admitted input. The result retains the original engine, target property, search depth and proof evidence. The coordinator publishes job-level checkpoint records and reports results in plan order. It accepts an existing checked job on resume even when the new worker count differs, provided the batch identity and evidence still verify.

The coordinator handles deadlines and cancellation. Cancelling ends active workers and marks queued jobs as unstarted. A deadline on one worker leaves other workers eligible to finish. Reports expose the coordinator and per-worker reservations, peak admitted worker count and each worker's committed-memory peak. Under pressure a new worker waits for the active jobs to release their reservations. If the host cannot admit even one worker, its result reports a memory resource limit.

Proof data and completed job records reside in the attempt directory. The controller currently assembles the aggregate result in memory under its reservation. Phase 2 subsystem performance needs its own frozen workloads and approved limits.

## Parallel worker qualification

The staged Windows executable compared two workers against a serial run of the same k-induction, Property Directed Reachability (PDR), and bounded model checking jobs. Both runs produced the same verdicts in plan order. The parallel run reserved 96 MiB for coordination and 144 MiB per worker under a 384 MiB plan. Its highest observed worker committed-memory peak was 9.99 MiB. A fresh resume independently reopened all three results without launching a worker. Deadline isolation, live cancellation, pending-job handling, and refusal of altered RTL after admission also passed. [Integration test](test_parallel_batch.ps1) · [Qualification](../../evidence/r-p2-workers/qualification.json) · [Serial checkpoint regression on the same executable](../../evidence/r-p2-workers-checkpoint/qualification.json)
