# Q3AFORMAL

Q3AFORMAL verifies application-specific integrated circuit (ASIC) register-transfer level (RTL) designs written in SystemVerilog. It checks properties from the supported SystemVerilog Assertions (SVA) profiles, produces independently checkable proofs, and replays counterexamples and cover witnesses from source.

## Platforms and downloads

| Platform | Distribution | Waveform viewer |
| --- | --- | --- |
| Windows x64 | [R17 Preview Windows ZIP](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/q3aformal-windows-x64-development-preview-r16.zip), the qualified R16 binary | Native viewer or offline Hypertext Markup Language (HTML) |
| Ubuntu 24.04 x86-64 | [R17 Preview Linux archive](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/q3aformal-linux-x64.tar.gz) | Offline HTML |
| macOS 15, Apple silicon (arm64) | GitHub Actions development artifact `q3aformal-macos-arm64` | Offline HTML |
| macOS 15, Intel (x86-64) | GitHub Actions development artifact `q3aformal-macos-x64` | Offline HTML |

[R17 Cross-platform Preview](https://github.com/nguyenquanicd/Q3AFORMAL/releases/tag/r17-preview) · [Tested macOS packages](https://github.com/nguyenquanicd/Q3AFORMAL/actions/runs/46013581165#artifacts) · [Specification](Q3AFORMAL_SPECIFICATION.md) · [User Guide (Vietnamese)](q3aformal/USER_GUIDE.md)

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

## Install

1. On Windows or Ubuntu, download the archive for your platform together with [install.py](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/install.py) and [INSTALL_SHA256SUMS](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/INSTALL_SHA256SUMS). Save all three files in the same directory.
2. On macOS, download and unpack the Actions artifact for your architecture. It contains the `.tar.gz` archive, installer and checksum manifest. Use Python 3 running natively on your Mac so the installer detects the intended architecture. [macOS build and installation guide](q3aformal/docs/macos.md)
3. From the directory containing these files, run `python install.py` on Windows or `python3 install.py` on Ubuntu and macOS. On Windows, `py -3 install.py` works with the Python launcher. The installer chooses the archive for the current operating system and processor architecture, checks its SHA-256 checksum and extracts it.

The default installation directory is `%LOCALAPPDATA%\Q3AFORMAL` on Windows and `~/.local/opt/q3aformal` on Ubuntu and macOS. Use `--prefix PATH` to choose a new destination or `--assets-dir PATH` to locate the downloads elsewhere. For manual installation, verify the archive against `INSTALL_SHA256SUMS` and extract it to a writable directory. [Installation details](q3aformal/USER_GUIDE.md#3-cài-đặt-và-build)

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

### Ubuntu and macOS shell

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

Open `cover-witness.html` in a browser. On macOS, run `open cover-witness.html`. On a headless machine, copy the file to your workstation. On all three platforms, use `trace view-vcd input.vcd` with the same executable and redirect its output to HTML to view a standalone VCD file.

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

## Ubuntu and macOS builds from source

Both platforms use CMake 3.20 or later, a C++17 compiler and Python 3. The platform guides cover prerequisites, local packaging and waveform debugging. [Linux build guide](q3aformal/docs/linux.md#build-and-validate) · [macOS build guide](q3aformal/docs/macos.md#build-and-package)

## Re-run qualification on GitHub Actions

| Workflow | What it verifies | Artifacts |
| --- | --- | --- |
| [R17 Ubuntu release audit](https://github.com/nguyenquanicd/Q3AFORMAL/actions/workflows/r17-ubuntu-release-audit.yml) | Downloads the published R17 assets, installs on Ubuntu 24.04 x86-64 outside Windows Subsystem for Linux (WSL), verifies the example proofs and renders cover and VCD waveforms. | Verdict, command logs, HTML and input VCD |
| [macOS CLI qualification](https://github.com/nguyenquanicd/Q3AFORMAL/actions/workflows/macos-cli.yml) | Builds on macOS 15 for Apple silicon and Intel, runs the shared formal regression, installs each package and runs the regression again with the packaged executables. | One installable archive, installer and checksum manifest per architecture |

With write access to the repository, open a workflow, choose **Run workflow**, select `main` and confirm. Open the run's **Summary** and download the ZIP from **Artifacts** when the run completes. [Ubuntu audit instructions (Vietnamese)](q3aformal/USER_GUIDE.md#kiểm-thử-gói-linux-bằng-github-actions)

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
| [q3aformal/scripts/](q3aformal/scripts/) | Build identity and packaging helpers. |
| [.github/workflows/](.github/workflows/) | Platform builds and release verification workflows. |

## Release qualification

R17 Preview passed all 15 Phase 2 benchmark runs on a GitHub-hosted Ubuntu 24.04 x86-64 virtual machine outside Windows Subsystem for Linux (WSL). The maximum measured wall time was 704.8 ms and the maximum sampled process-tree resident memory was 8.0 MiB. The packaged Linux command-line regression and automatic installation on both platforms also passed. [Workflow](https://github.com/nguyenquanicd/Q3AFORMAL/actions/runs/46002227798) · [Linux benchmark verdict](https://github.com/nguyenquanicd/Q3AFORMAL/releases/download/r17-preview/linux-x86-64-verdict.json)

R16 closed all four roadmap phases and 20 acceptance criteria in the approved Windows x64 scope. All 119 regression suites passed across the initial run and one isolated retry after a host-memory interruption. Phase 2 passed 15 source-revalidated runs. The longest run took 0.858 seconds and the highest measured process-tree working set was 55.62 MiB. [Release acceptance](q3aformal/evidence/r16/release-acceptance.json) · [Subsystem verdict](q3aformal/evidence/r16/phase2-acceptance/verdict.json)

The macOS 15 development builds passed the shared regression and installer checks on Apple silicon and Intel. [macOS qualification and packages](https://github.com/nguyenquanicd/Q3AFORMAL/actions/runs/46013581165)

## License

Q3AFORMAL is licensed under [Apache License 2.0](LICENSE). The GitHub Spec Kit workflow assets retain the [MIT license](q3aformal/.specify/LICENSE). The Windows ZIP includes the applicable compiler runtime notices.
