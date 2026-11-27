# Q3AFormal Phase 0 Benchmark Runner

`run_phase0_benchmarks.ps1` is a sequential Windows PowerShell 7 runner for a reviewed Phase 0 job manifest. It records raw elapsed time, peak working set, process exit code, Q3A formal status when present, exact listed input hashes, tool hashes, stdout/stderr, and a host/build profile. It does not decide whether a runtime or memory result is acceptable.

## Prepare and run

The owner approved the B-01 through B-05 matrix on 2026-11-21. Use [the approved manifest](phase0-jobs.approved.json) to reproduce the configuration and see [the benchmark report](../../evidence/benchmark/benchmark-report.md) for the measured build and results. Review changes to jobs, host or numeric limits before starting a new official measurement.

Create a new JSON file inside the Q3AFormal repository using this schema:

```json
{
  "schema": "Q3AFORMAL_PHASE0_BENCHMARK_JOBS_1",
  "host_profile_override": {
    "installed_memory_label": "16 GB",
    "source": "User-reported, 2026-11-20"
  },
  "jobs": [
    {
      "id": "B-XX",
      "executable": "prototype/bin/q3aformal-sourcecheck.exe",
      "working_directory": ".",
      "arguments": ["--bmc", "path/to/reviewed-project.q3a", "--property", "reviewed_property", "--frames", "N"],
      "input_files": ["path/to/reviewed-project.q3a", "path/to/reviewed-design.sv"],
      "expected_formal_status": "COVERED",
      "expected_exit_code": 0,
      "expected_diagnostic_regex": "optional source-located diagnostic text",
      "timeout_seconds": 0
    }
  ]
}
```

Paths for `executable`, `working_directory`, and `input_files` are resolved relative to the jobs JSON file and must remain within this repository. CLI arguments are passed as separate arguments and relative CLI paths are interpreted from `working_directory`; keep any paths embedded in those arguments inside the repository as well. List every RTL/VHDL source and project manifest that defines the job in `input_files`; each is SHA-256 hashed before execution. If Windows cannot report installed memory, `host_profile_override` records a user-reported label together with its provenance; the runner will not convert `GB` to bytes. Arguments may use `{JOB_OUTPUT_DIR}` for an isolated artifact folder under each run's output directory; such jobs must use the repository root as their working directory. `timeout_seconds: 0` means no process timeout; use an approved positive value for a bounded measurement. Leave expected fields out only for diagnostic runs; those are marked `UNASSESSED`.

After approval and the numeric-limit freeze, run the approved manifest once per measurement, choosing a new output directory for every run:

```powershell
.\prototype\benchmark\run_phase0_benchmarks.ps1 `
  -JobsPath .\prototype\benchmark\phase0-jobs.approved.json `
  -OutputDirectory evidence\benchmark\runs\run-YYYYMMDD-HHMMSS `
  -RequireCompleteHostProfile
```

The runner refuses to reuse an existing output directory and rejects resolved executable, working-directory, input, or output paths outside the repository. It does not inspect arbitrary path-bearing CLI arguments. Jobs run sequentially. Each job writes `<id>.stdout.txt` and `<id>.stderr.txt` and gets an isolated `<id>-artifacts/` folder; the run also produces `measurements.csv` and `environment.json`. `peak_working_set_bytes` is the maximum working set observed by the runner or reported by Windows for the Q3A process. It is not total system memory and does not include unrelated child processes.

Revalidate a current build's run of the approved manifest after measurement.

```powershell
.\prototype\benchmark\verify_phase0_compatibility.ps1 -RunDirectory evidence\benchmark\runs\run-YYYYMMDD-HHMMSS
```

The verifier compares the executable and workload digests, checks the input hashes from the accepted Gate B run, applies the approved thresholds, and reopens the four source-backed bundles. It writes threshold and bundle verdict tables in the run directory.

## Evidence limits

- `measurement_verdict` is `EXPECTED`, `MISMATCH`, `TIMEOUT`, `ENGINE_ERROR`, or `UNASSESSED`; it compares only the optional expected process exit code, formal status, and diagnostic regular expression supplied in the reviewed manifest.
- `formal_status` is read from recognized Q3A status lines. `NO_FORMAL_STATUS` means no recognized line was emitted; inspect the saved logs and do not infer proof from an exit code.
- `environment.json` captures Windows build, CPU model/core counts, installed memory, OS-visible physical memory, the Q3A executable hash, jobs-manifest hash, and metadata from `prototype/bin/q3a_build_info.hpp` when present. Installed memory comes only from the Windows `GetPhysicallyInstalledSystemMemory` API; `Win32_ComputerSystem.TotalPhysicalMemory` is recorded separately as OS-visible physical memory and is never relabeled as installed RAM. When the installed-memory API is unavailable, a user-reported override is retained with its source and no byte conversion. `host_profile_status` must be `CAPTURED`, `CAPTURED_WITH_FALLBACK`, or `CAPTURED_WITH_USER_OVERRIDE` before treating a run as a complete benchmark record; `INCOMPLETE` output is diagnostic only. The build-info header is not cryptographically embedded in the executable; perform and record a clean build before measurements.
- No numeric pass/fail threshold is applied by this runner. T029/T030 require approved jobs, host, limits, actual measurements, and a reviewed result report.
- This runner does not add independent semantic coverage, solver soundness evidence, proof-checker validation, or replay coverage. Those remain separate Phase 0 gaps.

## Windows runtime audit

Build both executables from source and run the audit with the GNU `objdump.exe` from the same toolchain.

```powershell
.\prototype\source\source_manager\build.ps1 -Compiler '<path-to-g++.exe>'
.\prototype\checker\build.ps1 -Compiler '<path-to-g++.exe>'
.\prototype\benchmark\audit_windows_runtime.ps1 -Objdump '<path-to-objdump.exe>' -Output '.\windows-runtime.json'
```

The audit records both executable digests, checks the direct Portable Executable imports against an explicit Windows allowlist, and rejects delay imports. It copies the executables into a fresh directory and uses a process-local `PATH` containing only Windows directories. It then runs Property Directed Reachability, rechecks the invariant certificate, and exercises standalone Deletion Resolution Asymmetric Tautology proof creation and checking. The build and audit tools are development dependencies.

## Product regression

Run the repository suite inventory with executables whose hashes match the verified Windows package.

```powershell
.\prototype\benchmark\run_product_regression.ps1 -Archive dist/q3aformal-phase1-windows-x64-product-candidate.zip -OutputDirectory evidence\release\product-regression-run-YYYYMMDD
```

To preserve the repository's installed executable, first stage the archive into an unused directory under `evidence`. The stage includes the exact executable pair, regression scripts and archived fixtures.

```powershell
$archive = (Resolve-Path 'dist/q3aformal-windows-x64-development-preview-r6.zip').Path
python prototype/benchmark/stage_product_regression.py --archive $archive --build-header evidence/r6/build/q3a_build_info.hpp --stage evidence/r6/stage --record evidence/r6/staged-regression-input.json
& ./evidence/r6/stage/prototype/benchmark/run_product_regression.ps1 -Archive $archive -OutputDirectory (Join-Path (Get-Location) 'evidence/r6/regression')
```

The runner executes suites sequentially, saves separate standard output and standard error for each suite, and checks the two packaged binary identities after every suite. Component harnesses that build temporary test executables and archived evidence checks are part of the same suite inventory. Pass `-Suite name1,name2` for a targeted retry and use a fresh output directory. The runner configures native output decoding as UTF-8.

Resume an interrupted regression by repeating its command with `-Resume` and the same archive, output directory, suite selection and watchdog. The runner checks the recorded package, executable and script identities. It retains completed suite rows and output, and moves incomplete artifacts aside before rerunning that suite. Resume requires `run-identity.json` from the original invocation. The regression watchdog does not change the approved native benchmark limits.

When a suite has a completed nonpassing result, repeat only that suite with `-Suite` and a fresh output directory after diagnosing its failure. Pass the original directory as `--regression` and each same-build attempt as `--regression-retry` to `audit_release_evidence.py`. The audit preserves every verdict and watchdog. It uses a later pass only when the package, binaries, runner, and test script match.

## Windows GUI workload preflight

For the planned Windows GUI qualification, check that the candidate executable matches the package payload and that it can reopen the frozen source-backed witness. Then recheck the indexed samples for the real witness and the synthetic stress trace.

```powershell
python prototype/benchmark/preflight_native_debug_workloads.py --archive <candidate.zip> --executable prototype/bin/q3aformal-sourcecheck.exe --output <new-preflight.json>
```

The preflight uses the source, trace, and workload digests recorded with the OD-07 proposal. It records the exact candidate hash and selected values for every case. The synthetic trace exercises viewport reads only. GUI latency and working-set qualification use a separate capture after the OD-07 limits are approved.

`compare_phase1_debug_limits.py` checks a visible Win32 capture against the approved OD-07 record and the candidate preflight. Pass `--limits`, `--preflight`, `--capture`, and `--output`. The approved record preserves the frozen proposal, identifies its digest, and records the approval reference and timestamp. A capture retains all three repetitions of each workload, with ordered frame values, cold and cached viewport timings, and process-tree working-set samples. The comparison rejects missing repetitions, mismatched values, or a capture taken before approval. It reports any exceeded limit per repetition.

`run_phase1_debug_capture.py` requires the approved OD-07 record, a candidate with the Win32 workload collector, and that candidate's preflight. Pass `--limits`, `--archive`, `--executable`, `--preflight`, and `--output`. It runs each repetition in a fresh process, records the native paint observations and process-tree memory samples, and applies the approved limits. An interrupted run retains partial observations and the error without producing an acceptance verdict. The collector's untimed mode is used for functional checks before numeric approval.

## Run compatibility cases on an extracted candidate

Pass `-ExecutablePath` to `run_phase0_benchmarks.ps1` to run the frozen Phase 0 or Phase 1 block workload on a Q3AFormal executable extracted inside the repository. The runner keeps the original workload manifest and records the selected binary's hash and reported build identity. Pass the same path to `verify_phase0_compatibility.ps1` or `verify_phase1_block_pilot.ps1` to reopen the resulting evidence. Pass it to `compare_phase1_block_limits.ps1` when checking the approved Phase 1 limits.

## Runner regression

Run `prototype/tests/test_benchmark_runner_memory_profile.ps1` to execute a short, isolated syntax/lowering smoke job and check the produced `environment.json`. The regression requires installed RAM to come from `GetPhysicallyInstalledSystemMemory` or from the explicitly sourced user override; it verifies that the OS-visible physical-memory field stays separate. Temporary manifests and run outputs are removed after the check.

## Phase 2 subsystem functional preflight

The first subsystem fixture is a four-stage, eight-bit hierarchical transport with a separately encoded implementation. The source and plans are hash-identified in the qualification record.

| Workload | Expected functional result |
| --- | --- |
| Monolithic | A one-step induction proof of `p_subsystem` and source-required bundle revalidation |
| Composed | Nine checked obligations for four stage guarantees and the same top property on the same source model |
| Sequential batch | Four stage proofs, each checked again on resume with one worker |
| Parallel batch | The same four proofs in plan order, checked again on resume with two workers |
| Encoded implementation | Output and state correspondence certificates in the matched-initial scope |

This preflight validates the workloads and evidence paths. It sets no performance verdict. A separate capture requires numeric thresholds for wall time and sampled peak process-tree working set. Memory and multi-clock workloads are tracked with the corresponding language-profile decisions. [Preflight script](preflight_phase2_subsystem.ps1) · [Input hashes and verdicts](../../evidence/r-p2-subsystem-workload/qualification.json)

### Approved subsystem measurements

The frozen workload file binds the executable command forms, seven fixture hashes, and the common transport model. The limit proposal requires three repetitions per workload. It sets 30 seconds per run and a sampled peak working-set cap of 512 MiB, with 768 MiB for parallel batch. These are proposed limits for the five transport workloads. The memory and multi-clock scopes remain separate additions to Phase 2. [Frozen cases](phase2-subsystem-workloads.json) · [Limit proposal](phase2-subsystem-limits.proposed.json)

The collector requires an approval record with the exact proposed thresholds, its SHA-256 digest, an approval reference and a dated approval timestamp. It checks the host and requires a functional preflight on the same executable and inputs. Wall time covers process launch through exit. The Windows sampler tracks current working set across the live process tree. Verification runs after the timed command and checks the proof or witness against the source. The collector preserves raw streams, timestamps, samples, and proof and verifier hashes. The audit mode recomputes the verdict and reruns source revalidation for each passing repeat. The verifier writes temporary audit logs and leaves the captured transcripts intact. The harness regression rejects a corrupt proof even when the stored artifact hashes have been refreshed.

```powershell
python prototype/benchmark/run_phase2_subsystem_benchmark.py capture --limits <approved.json> --preflight <qualification.json> --executable <q3aformal-sourcecheck.exe> --capture-dir <new-directory> --installed-memory-label '16 GB'
python prototype/benchmark/run_phase2_subsystem_benchmark.py audit --limits <approved.json> --preflight <qualification.json> --executable <q3aformal-sourcecheck.exe> --capture-dir <capture-directory>
```

The harness qualification runs native sampling and timeout probes on a disposable process, and verifies product evidence outside measurement mode. Its threshold tests keep artificial metric values in memory. [Collector](run_phase2_subsystem_benchmark.py) · [Harness test](test_phase2_subsystem_benchmark.py) · [Harness qualification](../../evidence/r-p2-bench-qa/qualification.json)
