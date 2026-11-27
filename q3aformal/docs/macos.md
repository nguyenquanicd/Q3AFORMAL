# Q3AFORMAL on macOS

The macOS port targets macOS 15 on Apple silicon (arm64) and Intel (x86-64). Both builds share the existing SystemVerilog frontend, formal engines, standalone proof checker and bundle format. Use the command line for proof and replay and an offline HTML page for waveform debugging.

## Build and package

Install the Xcode Command Line Tools, CMake 3.20 or later and Python 3. From the repository root, build for the current machine.

~~~sh
cmake -S q3aformal -B q3aformal/build/macos -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build q3aformal/build/macos --parallel 3
ctest --test-dir q3aformal/build/macos --output-on-failure
cpack --config q3aformal/build/macos/CPackConfig.cmake -B q3aformal/dist
~~~

This produces `q3aformal-macos-arm64.tar.gz` or `q3aformal-macos-x64.tar.gz`. A package downloaded from the macOS qualification workflow includes the installer and checksum manifest. With the three files in one directory, run `python3 install.py`. Use a native Python process so the architecture reported to the installer matches the machine. The default location is `~/.local/opt/q3aformal`. Choose a fresh directory with `--prefix` when testing multiple builds. The packages are development builds from the repository workflow. The R17 Preview release assets cover Windows and Linux.

For a local build, create `INSTALL_SHA256SUMS` from the archive in `q3aformal/dist` with `shasum -a 256` and run the installer from the repository root.

## Run a proof and view the waveform

From the installation directory, run the steps below. Choose new evidence directories when repeating a run.

~~~sh
q3a=./prototype/bin/q3aformal-sourcecheck
"$q3a" --version
"$q3a" prove prototype/pdr-pipeline.q3a --evidence-dir safety-proof
"$q3a" verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir safety-proof
"$q3a" prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir cover-proof --bundle-dir cover-witness
"$q3a" --verify-bundle cover-witness --require-source-model
"$q3a" debug cover-witness > cover-witness.html
open cover-witness.html
~~~

The examples report `PROVEN` and `COVERED`. Source-required verification reports `REVALIDATED`. Use `trace view-vcd INPUT.vcd` to generate a browser view for a standalone Value Change Dump file.

macOS uses the current process's physical memory footprint for the proof budget and the peak resident set size (RSS) for worker reporting. Parallel jobs apply the solver memory budget and time limit at checkpoints.
