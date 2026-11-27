# Q3AFormal Windows x64 development preview

This ZIP contains a Windows development build for evaluation. Its manifest records the `development-preview` channel and exact build flags. The output of `--version` identifies which profiles are included. The ZIP also contains the standalone proof checker, an ordinary one-clock project, a batch plan, and the compiler runtime notices.

Run these commands from the extracted directory in PowerShell.

```powershell
$exe = '.\prototype\bin\q3aformal-sourcecheck.exe'
& $exe --version
& $exe --help
& $exe prove prototype/pdr-pipeline.q3a --evidence-dir baseline-proof
```

## Exact small memories

Use a baseline project manifest with a supported synchronous memory, then provide an explicit limit on the number of cells. The checker proves enabled accesses stay within declared bounds before proving the selected property. Keep the source and manifest unchanged when reopening evidence.

```powershell
& $exe dev-prove-memory memory.q3a --property p_hold --output-dir memory-proof --max-cells 4
& $exe dev-verify-memory memory.q3a --property p_hold --evidence-dir memory-proof --max-cells 4
```

## Free positive-edge schedules

Use a baseline manifest containing the positive-edge clock domains. Each global step admits an independent choice of which clocks have an edge. Same-step edges use a common pre-state. A trace with an unfinished assumption at the boundary remains provisional.

```powershell
& $exe dev-check-events clocks.q3a --property c_hit --output-dir event-witness --frames 20
& $exe dev-verify-events clocks.q3a --property c_hit --evidence-dir event-witness
& $exe dev-gui-events clocks.q3a --property c_hit --evidence-dir event-witness
& $exe dev-prove-events clocks.q3a --property p_safe --output-dir event-proof
& $exe dev-verify-event-proof clocks.q3a --property p_safe --evidence-dir event-proof
```

## Guarded sampled-value functions

For a one-clock project, add `option profile Q3A-SAMPLED-VALUE-DEVELOPMENT` to its version 2 manifest. This enables `$stable`, `$changed`, `$rose` and `$fell` in assertions. The profile also supports one-hot checks and population counts on 1–64-bit expressions. History validity guards the first sample in the two-valued model. The memory and event development commands require the baseline manifest profile.

```powershell
& $exe prove sampled.q3a --engine pdr --property p_safe --evidence-dir sampled-proof
& $exe verify-pdr sampled.q3a --property p_safe --evidence-dir sampled-proof
```

## Strong eventual response

Builds whose `--version` includes `Q3A_ENABLE_DEVELOPMENT_LIVENESS` accept the `Q3A-LIVENESS-DEVELOPMENT` profile in version 2 manifests. Use a labeled assertion with `request |-> s_eventually response` or `request |=> s_eventually response` in a single positive-edge domain. Each side uses one same-sample Boolean expression. A repeatable `--justice` signal requires infinitely many high samples. The query uses explicit graph enumeration and reports a resource limit when the configured graph budget is exceeded.

```powershell
& $exe dev-check-liveness live.q3a --property p_reply --justice grant --evidence reply.q3live
& $exe dev-verify-liveness live.q3a --property p_reply --justice grant --evidence reply.q3live --vcd reply.vcd
& $exe trace view-vcd reply.vcd | Set-Content reply.html -Encoding utf8NoBOM
```

Use `--request SIGNAL --response SIGNAL` for a direct overlapped query. Waveform export requires a verified loop. The intermediate waveform includes the loop entry, loop span and closing sample. Keep the originating executable with its `.q3live` archive.

## Four-state checks and waveform replay

A build with `Q3A_ENABLE_DEVELOPMENT_FOUR_STATE` uses the opt-in `Q3A-FOUR-STATE-DEVELOPMENT` manifest profile. It supports sampled logic with `0`, `1`, `X`, and `Z`, finite assertions and cover goals, and bounded sampled history. Revision 6 extends this profile to nested module instances, procedural `case` and `casez`, packed arithmetic, comparisons, reductions, and variable shifts. Open a saved trace with the originating build.

```powershell
& $exe dev-prove-four-state prototype/four-state-cover.q3a --property p_history --evidence-dir history-proof --steps 2
& $exe dev-prove-four-state prototype/four-state-cover.q3a --property c_xz_then_zx --evidence-dir xz-cover --steps 1
& $exe dev-verify-four-state prototype/four-state-cover.q3a --property c_xz_then_zx --evidence-dir xz-cover --steps 1 --vcd xz-cover.vcd
& $exe trace view-vcd xz-cover.vcd | Set-Content xz-cover.html -Encoding utf8NoBOM
```

The revision 6 example also exposes an assertion inside the `capture` instance.

```powershell
& $exe dev-prove-four-state prototype/four-state-cover.q3a --property capture.p_history --evidence-dir child-proof --steps 2
& $exe dev-verify-four-state prototype/four-state-cover.q3a --property capture.p_history --evidence-dir child-proof --steps 2
```

The revision 7 example includes an intentionally failing assertion that exercises a partially out-of-range indexed slice. Save its counterexample and reopen it from the archived input samples.

```powershell
& $exe dev-prove-four-state prototype/four-state-cover.q3a --property p_demo_counterexample --evidence-dir counterexample --steps 0 --save-witness
& $exe dev-verify-four-state prototype/four-state-cover.q3a --property p_demo_counterexample --evidence-dir counterexample --steps 0 --vcd counterexample.vcd
```

The expected counterexample has `data=z1` and `window=xz`. The saved file is `counterexample.q3awitness`.

Revision 8 adds the finite sequence operators `or`, `and`, and `intersect`. Revision 9 adds `throughout`, `within`, and packed integral multiplication. For a single-clock project in the four-state profile, a cover such as `grant throughout (req ##2 ack)` requires `grant` on all three samples. A cover such as `(request ##1 accept) within (start ##4 finish)` accepts any contained request and accept pair and reports the enclosing finish sample. Select either labeled property with `--property NAME` and choose `--steps` large enough to include the intended endpoint.

Revision 10 adds `==?`, `!=?`, and procedural `casex`. It also exposes the exact Transition Intermediate Representation (T-IR) used by four-state checks. To compare the export with a result's `model_sha256`, save the canonical UTF-8 output without the console newline.

```powershell
& $exe dev-lower-four-state prototype/four-state-cover.q3a |
    Set-Content four-state-model.json -Encoding utf8NoBOM -NoNewline
Get-FileHash four-state-model.json -Algorithm SHA256
```

Revision 11 adds packed division and remainder plus module-local, parameterless sequence declarations. For example, the following cover checks the same named sequence twice without duplicating its body.

```systemverilog
sequence beat;
    valid ##1 ready;
endsequence
c_burst: cover property (@(posedge clk) beat()[*2]);
```

Use `--property c_burst --steps 3` to include both transfers. In RTL expressions, division and remainder with a zero divisor or an unknown operand produce all X bits.

A checked cover hit produces `cover.q3awitness`. Reopening it reproduces the sampled values from the source. A bounded cover miss produces a checked certificate. The VCD and HTML display the replayed samples and diagnostic markers.

Use new output directories for each run. Check the returned status and retain the evidence directory with the relevant source. Revision 16 completed Phase 2 and Phase 3 qualification for the approved profiles. [Release acceptance](../evidence/r16/release-acceptance.json)
