# Q3AFORMAL

Q3AFORMAL is a self-contained formal verification tool for application-specific integrated circuit (ASIC) register-transfer level (RTL) designs written in SystemVerilog. It runs on Windows x64 and Linux x86-64. It checks properties from the supported SystemVerilog Assertions (SVA) profiles, produces independently checkable proofs, and replays counterexamples and cover witnesses from source.

[R16 Windows release](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r16) · [Specification](Q3AFORMAL_SPECIFICATION.md) · [Release acceptance](q3aformal/evidence/r16/release-acceptance.json)

## Capabilities

| Area | What the tool supports |
| --- | --- |
| Frontend | Versioned project manifests, ordered source files, include paths, macros, parameters, and property bindings within the published profiles. |
| Formal engines | Bounded Model Checking (BMC), cover search, k-induction, and Property Directed Reachability (PDR) with the built-in Boolean satisfiability (SAT) solver. |
| Proof and replay | Standalone Deletion Resolution Asymmetric Tautology (DRAT) checking, source-backed bundle revalidation, and checked counterexample and cover replay. |
| Subsystem verification | Proof composition, exact synchronous memories with read-old collision semantics, explicit multi-clock event masks, checkpointed batches, and sequential equivalence. |
| Extended profiles | Four-state logic, finite temporal sequences, sampled-value functions, single-clock liveness with explicit fairness, parameter sweeps, and example Advanced eXtensible Interface 4 Lite (AXI4-Lite) checks. |
| Debug | Indexed traces, Value Change Dump (VCD) import and export, offline waveform viewing, and a native Windows viewer with source navigation and session persistence. |

A bounded pass applies to the checked bound. An unbounded proof requires a checked certificate under the recorded assumptions. Start with the [baseline profile](q3aformal/specs/003-phase1-block-mvp/plan.md#supported-phase-1-language-profile) and consult the [extended conformance matrix](q3aformal/specs/005-phase3-profile-expansion/conformance-matrix.md) for accepted syntax and limits.

## Install by operating system

The Python 3 installer detects the operating system and CPU architecture. It selects the Windows x64 ZIP or Linux x86-64 archive, verifies its SHA-256 checksum, and installs into a new user-owned directory. The asset directory must contain the matching package and its entry in `INSTALL_SHA256SUMS`.

From the repository root, when the release assets and the checksum manifest are available in `q3aformal/dist`, run:

~~~sh
python3 install.py
~~~

On Windows, use `py -3 install.py`. Use `--assets-dir` to select a separate distribution directory and `--prefix` to choose a fresh installation path. The default locations are `~/.local/opt/q3aformal` on Linux and `%LOCALAPPDATA%/Q3AFORMAL` on Windows.

## Install the R16 Windows package manually

1. Download `q3aformal-windows-x64-development-preview-r16.zip` from the [R16 release](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r16).
2. Optionally verify the download in PowerShell. The expected digest is in [SHA256SUMS](SHA256SUMS).
3. Extract the ZIP to a writable directory and open PowerShell in that directory.

~~~powershell
Get-FileHash .\q3aformal-windows-x64-development-preview-r16.zip -Algorithm SHA256
~~~

The ZIP contains both native executables, example projects, and compiler runtime notices. The executables run directly without an installer or a separate formal engine.

## Windows quick start

Run these commands from the extracted package. Use a new output directory for each proof or witness.

~~~powershell
$q3a = '.\prototype\bin\q3aformal-sourcecheck.exe'
& $q3a --version
& $q3a --help

# Prove the selected safety property and reopen its certificate.
& $q3a prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
& $q3a verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof

# Find a cover witness and check its source-bound bundle.
& $q3a prove prototype/pdr-cover.q3a --engine pdr --property p_hit `
    --evidence-dir cover-proof --bundle-dir cover-witness
& $q3a --verify-bundle cover-witness --require-source-model

# Open the witness in the native viewer.
& $q3a gui cover-witness
~~~

The first proof reports `PROVEN`. The second run reports `COVERED`, and source-required verification reports `REVALIDATED`.

### Projects and results

A minimal version 2 project manifest declares the top module, ordered SystemVerilog sources, profile, and property. Source paths are relative to the manifest.

~~~text
Q3AFORMAL_PROJECT 2
top pdr_example
source systemverilog "corpus/source-model-vectors/pdr_pipeline.sv"
option profile Q3A-P0-R0.9.1
option engine pdr
option depth 12
option property p_safe
~~~

The product proof command reports machine-readable outcomes and diagnostics separately. Evidence directories can contain query clauses, DRAT proofs and model identities. Witness bundles also contain the archived source, replay values and indexed trace. Recording a source snapshot makes it possible to reopen the exact model behind a result.

See the [English command guide](q3aformal/docs/windows-development-preview.md) for memory, multi-clock, four-state, liveness and waveform examples. The [Vietnamese user guide](q3aformal/USER_GUIDE.md) includes additional examples and command options.

## Windows build from source

Use PowerShell 7 and an x64 MinGW-w64 C++ compiler with C++17 support, such as MSYS2 UCRT64 GCC. Put its `g++` and `objdump` executables on your PowerShell path.

~~~powershell
Set-Location q3aformal
.\prototype\source\source_manager\build.ps1
.\prototype\checker\build.ps1
.\prototype\bin\q3aformal-sourcecheck.exe --version
~~~

The default build enables the baseline profile. To build with the full R16 feature switches, provide a separate output path.

~~~powershell
.\prototype\source\source_manager\build.ps1 `
    -Output build\r16\q3aformal-sourcecheck.exe `
    -EnableDevelopmentMemory -EnableDevelopmentEventMask -EnableDevelopmentSampledValues `
    -EnableDevelopmentLiveness -EnableDevelopmentFourState
~~~

The `Development` flag names are part of the build interface. The R16 qualification applies to the exact released executable pair and manifest. An independent rebuild has its own build identity.

## Linux build and quick start

Follow the [Linux build, packaging and execution guide](q3aformal/docs/linux.md). Linux uses the command-line proof engines and the offline HTML waveform viewer. The existing R16 Windows qualification applies to the published Windows package.

## Repository layout

| Path | Contents |
| --- | --- |
| [Q3AFORMAL_SPECIFICATION.md](Q3AFORMAL_SPECIFICATION.md) | Product architecture, semantics, requirements and acceptance criteria. |
| [q3aformal/prototype/source/](q3aformal/prototype/source/) | Project loading, frontend, elaboration, transition lowering, proof search, replay, trace storage and native debug. |
| [q3aformal/prototype/checker/](q3aformal/prototype/checker/) | Standalone DRAT proof checker and artifact handling. |
| [q3aformal/prototype/tests/](q3aformal/prototype/tests/) | Product and component regression tests. |
| [q3aformal/prototype/corpus/](q3aformal/prototype/corpus/) | Source-to-model vectors, language conformance matrices and example RTL. |
| [q3aformal/prototype/benchmark/](q3aformal/prototype/benchmark/) | Frozen workloads, resource measurement and evidence audit tools. |
| [q3aformal/specs/](q3aformal/specs/) | Phase plans, semantic reviews and acceptance records. |
| [q3aformal/scripts/](q3aformal/scripts/) | Build and Windows packaging support. |

The local migration includes the full historical qualification workspace. GitHub carries the source, specifications, release summaries and R16 binary asset. Historical run directories and build products are maintained in the local workspace.

## Release qualification

R16 closed all four roadmap phases and 20 acceptance criteria in the approved Windows x64 scope. All 119 regression suites passed across the initial run and one isolated retry after a host-memory interruption. Phase 2 passed 15 source-revalidated runs. The longest run took 0.858 seconds and the highest measured process-tree working set was 55.62 MiB. [Release acceptance](q3aformal/evidence/r16/release-acceptance.json) · [Subsystem verdict](q3aformal/evidence/r16/phase2-acceptance/verdict.json)

Q3AFORMAL is licensed under [Apache License 2.0](LICENSE). The GitHub Spec Kit workflow assets retain the [MIT license](q3aformal/.specify/LICENSE). The Windows ZIP includes the applicable compiler runtime notices.
