# Fair-cycle liveness kernel

This Phase 3 development component decides whether a finite, explicit product graph admits a fair infinite execution whose suffix remains in a monitored violation region. The graph must define the complete design and obligation-monitor state, every initial vertex, and every allowed edge. The caller labels each vertex as pending or clear and supplies a 64-bit set of state justice conditions. Each required justice condition must be visited infinitely often. The search permits finite dead ends and does not add self-loops to them. [Generalized temporal-property model checking](https://orbi.uliege.be/bitstream/2268/164300/1/CVWY%20FMSD%2092.pdf)

| Outcome | Checked evidence |
| --- | --- |
| `Violation` | An initial prefix followed by a nonempty cycle that stays in the pending region and encounters every required justice label. |
| `NoViolation` | A fair execution of the environment plus evidence that every reachable pending cycle misses a required label. |
| `NoFairExecution` | Evidence that every reachable cycle misses a required label. Use this outcome to diagnose the environment. |
| `InvalidGraph` | An initial vertex or edge endpoint is outside the graph. |

## Search and independent validation

The search computes prefix reachability across the full graph, then iteratively partitions reachable pending vertices into strongly connected components. A component can sustain a fair cycle if it contains a directed cycle and its combined justice labels cover the required set. The extracted counterexample visits a representative of each required condition and returns to the loop entry. The loop may traverse a vertex more than once. The search also checks the complete reachable graph for a fair execution when it finds no violation cycle.

The independent validator checks each witness edge, the initial state, cycle closure, its pending-region membership, and the justice labels on the loop. For an exclusion, it checks that the recorded reachable set contains every initial vertex and is closed under every edge. Rank may stay equal or increase within the search region, so a closed loop must remain at one rank. Every rank either has a single vertex without a self-edge or lacks a required justice condition. A checker can therefore validate the exclusion locally without rerunning the strongly connected component search.

## Check a SystemVerilog design

Build with `-EnableDevelopmentLiveness` to add the explicit liveness command. The query takes one-bit RTL signal names from the elaborated model. It checks that every request has a response at the same sample or at a later sample. Each repeatable `--justice` predicate requires its named signal to be high infinitely often. The command applies the project's same-sample scalar assumptions at each vertex. A temporal implication or a delayed sequence in an assumption is rejected.

```powershell
.\prototype\source\source_manager\build.ps1 -EnableDevelopmentLiveness `
    -Output evidence\live-local\q3aformal-sourcecheck.exe
& .\evidence\live-local\q3aformal-sourcecheck.exe dev-check-liveness project.q3a `
    --request req --response ack --justice grant
```

Each graph vertex includes the sampled state, an assignment to every unbound signal, and one obligation bit. At an edge the next-state equations update together and the successor can take any legal assignment for its new sample. Source state is initially unconstrained except for generated history-valid bits. RTL reset follows the design equations. The obligation bit starts clear and becomes set on an unacknowledged request. It stays set until a response. This is the non-counted eventual-response property. One response may discharge several earlier requests.

The default and maximum search sizes are 65,536 candidate sample vertices and 1,048,576 edges. Use `--max-vertices` and `--max-edges` for smaller bounds. The vertex budget applies before assumption filtering, and the edge budget applies after filtering. `--timeout-ms`, `--memory-mib`, and `--cancel-file` use standard run controls. A cutoff returns an incomplete result. `NO_FAIR_EXECUTION` also returns the incomplete exit class, since the requested fairness leaves no admissible infinite execution.

A conclusive JSON result identifies the elaborated model, manifest, build, and query signals. For a lasso it includes packed sample data, the signal layouts in least-significant-first order, and the closing sample that repeats the sample at `loop_start`. The native component validates evidence against the generated graph before returning a result. [Source fixture and independent replay](test_source_liveness.ps1) · [Qualification](../../evidence/p3-live-source/source-tests/qualification.json)

### Named SystemVerilog Assertions

Set `option profile Q3A-LIVENESS-DEVELOPMENT` in a version 2 project manifest. The build flag `-EnableDevelopmentLiveness` makes that profile available. Select an inline assertion label or the label of an assertion that instantiates a named property.

```systemverilog
p_reply: assert property (@(posedge clk) (req && enable) |-> s_eventually ack);
p_next_reply: assert property (@(posedge clk) req |=> s_eventually ack);
```

`|->` allows a response on the triggering sample. `|=>` starts looking from the next sample. Both require an actual response at some eligible future sample along every admissible infinite run. The profile supports one same-sample Boolean expression on each side. Range forms, history functions in these operands, sequence antecedents with delays and liveness assumptions or covers are outside this profile. Justice constraints are supplied separately as one-bit RTL signals. [IEEE Std 1800-2017, sections 16.12.7 and 16.12.13](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

```powershell
& $exe dev-check-liveness project.q3a --property p_reply --justice grant --evidence reply.q3live
& $exe dev-verify-liveness project.q3a --property p_reply --justice grant --evidence reply.q3live
```

The overlapped monitor updates its outstanding bit with `(outstanding || antecedent) && !consequent`. The nonoverlapped monitor updates it with `(outstanding && !consequent) || antecedent`. This preserves a new nonoverlapped obligation even when the same sample answers an earlier request. A violating loop must keep the outstanding bit set and the consequent false. If a request never receives an eligible response, an infinite continuation eventually stays in that region. Conversely, an infinite continuation in that region contains a request whose response never arrives.

The evidence binds the selected assertion label and the regenerated model. Use the originating executable for archives created before named-property support. The direct `--request` and `--response` form remains available. Bounded model checking, k-induction and Property Directed Reachability reject attempts to prove the unbounded assertion and continue to handle their supported safety properties. [Named SVA regression](test_sva_liveness.ps1) · [Windows qualification](../../evidence/p3-live-sva/qa/qualification.json)

### Save and reopen evidence

Pass `--evidence FILE` to save a checked `.q3live` result. Replay it with the original project, predicates, justice list in the same order, and graph limits.

```powershell
$exe = '.\evidence\live-local\q3aformal-sourcecheck.exe'
& $exe dev-check-liveness project.q3a --request req --response ack --justice grant --evidence result.q3live
& $exe dev-verify-liveness project.q3a --request req --response ack --justice grant --evidence result.q3live
```

The saved file records the model, manifest and build digests, the exact query, and either a lasso, a rank exclusion, or both. The reopener regenerates the source graph and checks the stored proof or witness without rerunning the cycle search. The JSON result retains the original semantic status and includes `evidence_revalidated: true` and the evidence digest. A copy of an identical project at a different path can be used to reopen the artifact. The original build identity is required.

Publication stages and checks the complete file before moving it to its destination. A pre-existing path is preserved. [Archive regression](test_liveness_evidence.ps1) · [Windows archive qualification](../../evidence/p3-live-archive/qa/qualification.json)

### Inspect the loop waveform

Add `--vcd FILE` when reopening an archive that contains a verified loop. The exporter reconstructs every waveform sample from the RTL model and the stored state and input assignments. It emits the prefix, one traversal of the loop, and the final sample that closes it.

```powershell
& $exe dev-verify-liveness project.q3a --property p_reply --justice grant `
    --evidence reply.q3live --vcd reply.vcd
& $exe trace view-vcd reply.vcd | Set-Content reply.html -Encoding utf8NoBOM
```

Under `__q3a_liveness`, `request` and `response` show the evaluated query predicates. `outstanding` shows the monitor state before the current sample updates it. `loop_start` marks the loop entry, `loop_active` spans the loop, and `loop_close` marks the repeated closing sample. The exporter supports a violating loop or a feasible fair loop. An archive reporting `NO_FAIR_EXECUTION` has no loop to export.

Q3AFormal's View VCD tool can read this Value Change Dump (VCD) file and produce a standalone HTML waveform. The wave is a debug derivative and the original `.q3live` file carries the evidence for source revalidation. The export reports its SHA-256 digest and preserves an existing destination. [Waveform regression](test_liveness_vcd.ps1) · [Windows qualification](../../evidence/p3-live-vcd/qa/qualification.json)

## Windows qualification

The test independently enumerates closed walks using the product of vertex and accumulated justice labels. It compared the search and evidence validator on all directed three-vertex graphs, all pending labels, all assignments of two justice bits, and all four required masks, for 1,048,576 cases with a fixed initial vertex. Separate cases check multiple initial vertices, unreachable cycles, dead ends, a required bit at position 63, false witness and rank evidence, and a 100,001-vertex graph. [Regression source](test_fair_cycle.cpp) · [Qualification](../../evidence/p3-fair-cycle/qualification.json)

From the Q3AFormal workspace, compile and run the component test with a C++17 compiler.

```powershell
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -static `
    -I prototype/source/liveness prototype/source/liveness/fair_cycle.cpp `
    specs/005-phase3-profile-expansion/test_fair_cycle.cpp -o fair-cycle-test.exe
.\fair-cycle-test.exe
```
