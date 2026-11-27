# T029 Benchmark Runner Progress

**Date:** 2026-11-19  
**Task status:** Historical runner and preflight evidence. T029 and T030 closed on 2026-11-21 after all eight approved jobs passed the [measured benchmark](../../../evidence/benchmark/benchmark-report.md).

## Runner smoke evidence

`prototype/benchmark/run_phase0_benchmarks.ps1` was parsed by the PowerShell 7 parser and run against the existing `counter4_pass.sv` syntax-parse command through a temporary job manifest. The process exited with code 0; the runner classified the explicitly expected exit code as `EXPECTED`, recorded the listed input SHA-256, and wrote stdout/stderr logs plus `measurements.csv` and `environment.json`.

The final runner smoke reported 94.132 ms elapsed and a peak working set of 2,064,384 bytes. These numbers measure one syntax-parse smoke invocation in the managed environment. They are not Q3A formal benchmark results and have no performance threshold applied. `prototype/tests/test_benchmark_runner_memory_profile.ps1` now reproduces a short runner smoke and checks that the installed-memory label/source remains distinct from OS-visible physical memory; it passed with the user-reported `16 GB` override and a separate OS-visible byte count.

## Host profile boundary

The runner captured Windows 10 Home Single Language, version 25H2, build 26200.9974, AMD Ryzen 7 7445HS, 6 physical cores, 12 logical processors, and AMD64. The OS-visible physical memory API returned 16,357,158,912 bytes. The managed session denied both CIM access and `GetPhysicallyInstalledSystemMemory`; the user supplied `16 GB`, recorded verbatim with source `User-reported, 2026-11-20`. The runner marks this `CAPTURED_WITH_USER_OVERRIDE`, leaves the installed-memory byte count null, and does not substitute OS-visible memory for the user-reported installed memory. The runner now reads the installed-memory byte field only through `GetPhysicallyInstalledSystemMemory`; `Win32_ComputerSystem.TotalPhysicalMemory` is retained only as OS-visible physical memory.

The known Q3A compiler metadata is `g++.exe (Rev4, Built by MSYS2 project) 16.2.0`; the build script uses C++17, `-O2`, `-Wall`, `-Wextra`, and `-Wpedantic`. The executable hash and build-info-header hash are recorded by the runner, with a clean rebuild still required before formal performance measurements.

## Benchmark job preflight

The proposed manifest is [`prototype/benchmark/phase0-jobs.proposed.json`](../../benchmark/phase0-jobs.proposed.json). All eight jobs were checked for valid manifest paths and expected diagnostic regular expressions. The formal fixtures were exercised before measuring:

| Job | Functional preflight result | Durable evidence / boundary |
|---|---|---|
| B-01 counter wrap | `PROVEN`; reopened bundle accepted both base and induction-step DRAT artifacts. | `evidence/benchmark/preflight/B-01-counter4-2026-11-19/`; proof scope remains generated T-IR. |
| B-02 counter mutation | `BOUNDED_FAIL`; decoded witness replayed successfully; reopened bundle revalidated it. | `evidence/benchmark/preflight/B-02-counter4-fail-2026-11-19/`; one-transition bounded failure only. |
| B-03 overlapping `casez` | `PROVEN`; reopened bundle accepted both proof artifacts; the candidate invariant was compared over all 16 selector values. | `evidence/benchmark/preflight/B-03-casez-2026-11-19/`; candidate property still needs owner review. |
| B-04 handshake transfer cover | `COVERED`; witness replayed successfully; reopened bundle revalidated it. | `evidence/benchmark/preflight/B-04-handshake-2026-11-19/`; bounded witness, not proof of reachability beyond this model. |
| B-05a `disable iff` | Parse rejection: expected `)` before `iff`; exit 1. | No formal query started. |
| B-05b multi-clock | Parse rejection at second clock event; exit 1. | No formal query started. |
| B-05c unlisted `$rose` | Source-located unsupported system-function diagnostic; exit 1. | No formal query started. |
| B-05d X/Z data literal | Source-located two-state-profile diagnostic; exit 1. | No formal query started. |

These are job-correctness and evidence-reopen checks, not benchmark timing/memory runs. They do not close T029. The B-03 property and B-04 cover intent/bound are proposals and require owner review before measurement.

## Official measurement

The owner approved the jobs, expected outcomes and resource limits before the measured run. See the [approval record](../../../docs/phase0/benchmark-threshold-proposal.md) and the [benchmark report](../../../evidence/benchmark/benchmark-report.md).
