# Q3AFORMAL

Q3AFORMAL is a self-contained formal verification tool for application-specific integrated circuit (ASIC) register-transfer level (RTL) designs written in SystemVerilog. It runs on Windows x64 and Linux x86-64. It checks properties from the supported SystemVerilog Assertions (SVA) profiles, produces independently checkable proofs, and replays counterexamples and cover witnesses from source.

[R17 Cross-platform Preview](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r17-preview) · [Specification](Q3AFORMAL_SPECIFICATION.md) · [User Guide (Vietnamese)](q3aformal/USER_GUIDE.md)

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

## Install R17 Preview

Download [install.py](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/install.py), [INSTALL_SHA256SUMS](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/INSTALL_SHA256SUMS), and the archive for your platform into the same directory. The installer requires Python 3, detects the operating system and processor architecture, and verifies the archive's SHA‑256 checksum before extraction.

| Platform | Download | Install command |
| --- | --- | --- |
| Windows x64 | [Windows ZIP](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/q3aformal-windows-x64-development-preview-r16.zip) | `python install.py` |
| Ubuntu 24.04 x86-64 | [Linux archive](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/q3aformal-linux-x64.tar.gz) | `python3 install.py` |

On Windows, `py -3 install.py` also works when the Python launcher is installed. The Windows archive in R17 Preview is the original, qualified R16 package. The default installation directories are `%LOCALAPPDATA%\Q3AFORMAL` on Windows and `~/.local/opt/q3aformal` on Linux. Use `--prefix PATH` for a new destination or `--assets-dir PATH` to locate the downloads elsewhere. For manual installation, verify the archive against `INSTALL_SHA256SUMS` and extract it to a writable directory. [Installation details](q3aformal/USER_GUIDE.md#3-cài-đặt-và-build)

## Quick start

Use the default installation directory below, or substitute the path selected with `--prefix` or manual extraction. Choose new output directories when rerunning the examples. `prove` reports `PROVEN` for the safety property and `COVERED` for the cover example. `--verify-bundle` verifies the archived source and witness and reports `Q3A_BUNDLE_STATUS REVALIDATED`.

### Windows PowerShell

~~~powershell
Set-Location "$env:LOCALAPPDATA\Q3AFORMAL"
$q3a = '.\prototype\bin\q3aformal-sourcecheck.exe'
& $q3a --version
& $q3a prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
& $q3a verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof
& $q3a prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir cover-proof --bundle-dir cover-witness
& $q3a --verify-bundle cover-witness --require-source-model
& $q3a gui cover-witness
~~~

To save an offline waveform page, run `& $q3a debug cover-witness > cover-witness.html` in PowerShell 7.4 or later and open the HTML file in a browser.

### Linux shell

~~~sh
cd "$HOME/.local/opt/q3aformal"
q3a=./prototype/bin/q3aformal-sourcecheck
"$q3a" --version
"$q3a" prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
"$q3a" verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof
"$q3a" prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir cover-proof --bundle-dir cover-witness
"$q3a" --verify-bundle cover-witness --require-source-model
"$q3a" debug cover-witness > cover-witness.html
~~~

Open `cover-witness.html` in a browser. On a headless machine, copy the file to your workstation. On either platform, use `trace view-vcd input.vcd` with the same executable to generate an HTML page for a standalone Value Change Dump file.

## Projects and results

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

## Linux build from source

Follow the [Linux build, packaging and execution guide](q3aformal/docs/linux.md). Linux uses the command-line proof engines and the offline HTML waveform viewer. The existing R16 Windows qualification applies to the published Windows package.

## macOS build and installation

The macOS development build targets macOS 15 on Apple silicon and Intel. Build and run the shared regression with CMake, or use the package generated for your architecture by the macOS workflow. The installer selects the archive automatically. Use the offline HTML waveform viewer on macOS. [macOS guide](q3aformal/docs/macos.md) · [macOS qualification workflow](https://github.com/nguyenquanicd/Q3AFORMAL/actions/workflows/macos-cli.yml)

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

The local migration includes the full historical qualification workspace. GitHub carries the source, specifications, release summaries and R17 Preview downloads. Historical run directories and build products are maintained in the local workspace.

## Release qualification

R17 Preview passed all 15 Phase 2 benchmark runs on a GitHub-hosted Ubuntu 24.04 x86-64 virtual machine outside Windows Subsystem for Linux (WSL). The maximum measured wall time was 704.8 ms and the maximum sampled process-tree resident memory was 8.0 MiB. The packaged Linux command-line regression and automatic installation on both platforms also passed. [Workflow](https://github.com/nguyenquanicd/Q3AFORMAL/actions/runs/46002227798) · [Linux benchmark verdict](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/linux-x86-64-verdict.json)

R16 closed all four roadmap phases and 20 acceptance criteria in the approved Windows x64 scope. All 119 regression suites passed across the initial run and one isolated retry after a host-memory interruption. Phase 2 passed 15 source-revalidated runs. The longest run took 0.858 seconds and the highest measured process-tree working set was 55.62 MiB. [Release acceptance](q3aformal/evidence/r16/release-acceptance.json) Â· [Subsystem verdict](q3aformal/evidence/r16/phase2-acceptance/verdict.json)

Q3AFORMAL is licensed under [Apache License 2.0](LICENSE). The GitHub Spec Kit workflow assets retain the [MIT license](q3aformal/.specify/LICENSE). The Windows ZIP includes the applicable compiler runtime notices.
