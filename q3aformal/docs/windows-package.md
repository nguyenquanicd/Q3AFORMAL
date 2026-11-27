# Q3AFormal Windows x64 candidate

This package contains the Phase 1 command-line executables, two example projects, a batch plan, the package manifest, and compiler-runtime notices. It is an internal candidate for verification. The tools run directly from the extracted directory.

Open PowerShell in the directory containing this file. Use `--help` for product command syntax and `--version` for the machine-readable build identity.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe --help
.\prototype\bin\q3aformal-sourcecheck.exe --version
```

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove prototype/pdr-pipeline.q3a --evidence-dir assertion-proof
.\prototype\bin\q3aformal-sourcecheck.exe verify-pdr prototype/pdr-pipeline.q3a --property p_safe --evidence-dir assertion-proof

.\prototype\bin\q3aformal-sourcecheck.exe prove prototype/pdr-cover.q3a --evidence-dir cover-proof
.\prototype\bin\q3aformal-sourcecheck.exe verify-pdr prototype/pdr-cover.q3a --property p_never --evidence-dir cover-proof
```

Choose a new certificate directory under an existing parent. Proof records are staged on disk. The final directory appears after all three checks pass, and an existing destination is preserved.

A single PDR run can set its search budget using `--max-queries N`. The default is 10,000. The effective setting appears in the JSON result; the deadline and memory policy still apply.

The assertion proof should report `PROVEN`. The cover proof should report `UNREACHABLE`. For a replayed witness, select `p_hit` explicitly. Choose unused output directories for each run.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove prototype/pdr-cover.q3a --engine pdr --property p_hit --evidence-dir unused-cover-proof --bundle-dir cover-hit
.\prototype\bin\q3aformal-sourcecheck.exe --verify-bundle cover-hit
```

The cover-hit run should report `COVERED` and the bundle check should report `REVALIDATED`.

Open the included Windows waveform and source viewer on the cover witness.

~~~powershell
.\prototype\bin\q3aformal-sourcecheck.exe gui cover-hit
~~~

The viewer revalidates the witness and reconstructs its archived source model before opening. Use the navigation buttons to change the viewport, select a signal to inspect its RTL, and open or save a session for the same bundle.

A custom `Q3AFORMAL_BATCH 2` plan can append `max_queries N` to individual PDR jobs. The included sample plan uses version 1. Run the included batch plan to check three properties in order. The example returns exit code 1 because the bounded job remains inconclusive. Its three results are `PROVEN`, `FAIL`, and `BOUNDED_PASS`.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe prove-batch prototype/pdr-pipeline.q3a --plan prototype/batch-pipeline.q3b --output-dir batch-results
Get-Content -LiteralPath batch-results/batch.json -Raw
```

The PDR result JSON records the resolved proof configuration, certificate directory, and hashes of the checked query and proof files. To view an external Value Change Dump (VCD) file, generate an HTML page.

```powershell
.\prototype\bin\q3aformal-sourcecheck.exe trace view-vcd input.vcd > external-waveform.html
```

Open the page after the command exits with code 0. Use the signal filter and **Pin signal** to compare values at the same timestamp.


## Macro provenance

Use the version 2 project manifest to inspect the ordered token stream and macro origins.

~~~powershell
.\prototype\bin\q3aformal-sourcecheck.exe --preprocess-project prototype/pdr-pipeline.q3a > preprocess.json
~~~

For each unit, the report includes the tokens, invocation positions and visited macro definitions. Expansion ranges are half-open indexes into the reported tokens. Compare the source-set digest with that of a proof run using the same settings.

The local Windows runtime provides the operating-system interfaces. The compiler's runtime support is linked statically. The `licenses` directory preserves the installed toolchain's notice files used for this package inventory. `package-manifest.json` records the source build identifier, compiler configuration, and Secure Hash Algorithm 256-bit (SHA-256) digest of every payload file.
