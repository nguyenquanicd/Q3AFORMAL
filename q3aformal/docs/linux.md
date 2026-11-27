# Q3AFORMAL on Linux

## Scope

The initial Linux build targets Ubuntu 24.04 x86-64. It reuses the SystemVerilog frontend, transition model, formal engines, Deletion Resolution Asymmetric Tautology (DRAT) checker, trace formats, and accepted R16 source fixtures. Linux build identities include the compiler and source digests. Source-required verification is the appropriate way to reopen a compatible archived result.

The Linux executable provides the proof and replay command line and offline Hypertext Markup Language (HTML) debugging. The graphical Windows workbench stays available with the Windows package. Linux uses kernel SHA-256 through the kernel cryptographic socket interface (`AF_ALG`), a mounted proc filesystem for executable identity and memory accounting, and an output filesystem that supports atomic no-replace rename. Worker memory limits use address-space limits and process data accounting, and the worker peak metric is resident memory.

## Build and validate

Use CMake 3.20 or later, a C++17 compiler, and Python 3 to build. Run these commands from the repository root.

~~~sh
cmake -S q3aformal -B q3aformal/build/linux -DCMAKE_BUILD_TYPE=Release
cmake --build q3aformal/build/linux --parallel 2
ctest --test-dir q3aformal/build/linux --output-on-failure
cpack --config q3aformal/build/linux/CPackConfig.cmake -B q3aformal/dist
~~~

To prepare an offline installer directory for both platforms, place the accepted Windows R16 ZIP beside the Linux archive. Check the Windows ZIP against the published R16 checksum and generate the installer manifest from the authenticated assets.

~~~sh
(
  cd q3aformal/dist
  sha256sum q3aformal-linux-x64.tar.gz q3aformal-windows-x64-development-preview-r16.zip > INSTALL_SHA256SUMS
)
python3 install.py --prefix "$HOME/.local/opt/q3aformal"
~~~

The package includes both executables and the existing RTL and project examples. Targets with other CPU architectures or older system libraries need qualification before distribution. The prebuilt package uses the GNU C and C++ runtimes.

## Run a proof

From the extracted package or installation directory, run the bundled example with a fresh evidence directory.

~~~sh
q3a=./prototype/bin/q3aformal-sourcecheck
"$q3a" --version
"$q3a" prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
"$q3a" verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof
"$q3a" prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir cover-proof --bundle-dir witness
"$q3a" --verify-bundle witness --require-source-model
"$q3a" debug witness > witness.html
~~~

Open the generated HTML file in a browser for offline waveform and source inspection. Use `trace view-vcd` to view a standalone Value Change Dump (VCD) file.

## Linux port plan

| Work item | Acceptance evidence |
| --- | --- |
| Introduce Linux file, process, cancellation, SHA-256 and memory adapters | Build both executables from the existing C++ source and run a checked proof, standalone DRAT check, source replay and budget control. |
| Port subsystem and extended commands | Reuse the frozen Phase 2 transport workloads and Phase 3 source fixtures to exercise composition, parallel checkpointing, equivalence, four-state logic and liveness. |
| Package and select by platform | Build the Linux archive, use the accepted Windows archive, verify both checksums, and exercise automatic selection on each OS. |
| Record compatibility | Compare reproducible model and query identities with available Windows evidence. Qualify Linux-specific benchmarks on an identified host before claiming Linux performance acceptance. |

## Validation

The initial build passed the command-line regression on Ubuntu 24.04 x86-64 under Windows Subsystem for Linux (WSL), using GNU Compiler Collection (GCC) 13.3.0 and `-O1 -DNDEBUG`. The regression exercises Property Directed Reachability (PDR), standalone proof checking, source replay, waveform export, cancellation, memory reserve, all five frozen subsystem workloads, and representative exact-memory, multi-clock, four-state and liveness cases.

The installer selected and installed the correct package on Windows and Linux. For the bundled pipeline, the three PDR query files in Conjunctive Normal Form (CNF) matched the Windows R16 output byte for byte. Linux also recompiled the archived source and replayed a cover witness produced on Windows.

Broader Linux distribution and performance qualification remains open. The Linux build uses the system memory figures reported by `/proc`. Deployments with container memory quotas should configure a proof budget using `Q3A_MEMORY_LIMIT_MIB` and set an appropriate worker limit for parallel jobs.
