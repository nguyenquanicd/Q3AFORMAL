# Q3AFormal Phase 2 Memory and Equivalence Review

This review proposes state-model decisions and acceptance cases for memory and sequential equivalence.

## Exact memory profile

Introduce a dedicated Transition Intermediate Representation (T-IR) memory object carrying depth, data width, index range, initialization policy, owning clock domain, write ports, and read observation points. Preserve the source location of the declaration and each port. A first exact, finite profile can cover a constant-depth, fixed-width, one-dimensional unpacked array with one synchronous writer and a synchronous read-old port on the same clock. Lower each cell to a finite bit-vector state value. Use one decoded write enable per cell and a selected pre-state value for the read. The memory style and its SystemVerilog meaning must be reviewed against the language standard before extending the profile. [IEEE 1800-2023](https://standards.ieee.org/ieee/1800/7743/)

For an enabled write to legal address \(w\), cell \(i\) becomes write data if \(i=w\) and holds otherwise. A synchronous enabled read at legal address \(r\) samples \(M_t[r]\), including when \(r=w\). Its destination holds when its read enable is false unless the supported RTL explicitly defines a different update. Off-domain steps hold both state and the read destination. Preserve unconstrained initial cells unless a supported initialization or proved reset contract supplies their values.

- An enabled invalid address needs an explicit checked reachability obligation. A two-valued profile cannot silently clamp, wrap, or choose zero for a SystemVerilog read whose value requires unknown-state semantics. If the range cannot be justified under the declared environment, report an unsupported or inconclusive memory result with the access location.
- Multiple writes, ambiguous read-during-write modes, masked writes, asynchronous observations, whole-array reset, and multi-clock memory each need their own source semantics and checks before acceptance.
- Record depth, width, address interpretation, collision policy, and initialization in model and cache identities. For the first exact profile, replay keeps complete small memory states so the independent evaluator can detect inconsistent aliasing and writes.

A later scalable abstraction may represent only selected memory observations, but a checked simulation relation must cover every concrete step used in a proof. In an abstract counterexample, any modeled read that cannot be reproduced by the concrete write history prevents a published failure. Large array abstractions and refinement need independent proof and witness checks. Numeric limits and benchmark cases belong to a separately approved measurement record.

### Range proof order

Keep enabled out-of-range accesses visible to the model checker. Derive one safety condition for each access from its source enable and address expression. Check those conditions on the same reachable states and sampled environment as the requested property. In particular, inserting an access bound as an assumption would exclude the behavior that the obligation must detect.

The internal equation may give an invalid write a hold transition and an invalid synchronous read an arbitrary two-valued successor. The guard observes the pre-state and input before either successor is selected. Every trace up to its first invalid access therefore uses only exact legal transitions, and the first invalid access remains observable. A source proof of every guard establishes that the placeholder branches are unreachable within the checked environment. Its certificate must identify the exact model, initialization, environment, and per-site bound used by the main property. Unknown guard results or a reachable invalid access stop publication of a normal proof or failure result for that scope.

Reopening a proof repeats source lowering and validates every required range certificate before checking the requested property. Reopening a witness checks the enabling expressions and exact pre-state read at every sampled access. A changed depth, range direction, access enable, bound, or proof context invalidates the saved identity.

### Scalar reference qualification

The three-word, two-bit reference fixture represents every memory cell as a separate register. Property Directed Reachability (PDR) proved enabled read and write address legality, read-old behavior, the disabled-read hold, and single-cell updates. A cover run reached a collision with different stored and incoming values. Separately removing address guards produced invalid read and write witnesses. Selecting write-first behavior produced a read-old violation. All four witnesses reopened from source. The standalone checker accepted 15 Deletion Resolution Asymmetric Tautology (DRAT) obligations, three per proof.

The fixture uses the existing scalar Register-Transfer Level (RTL) profile. Native array syntax admission, generated range obligations, and source-to-model binding remain part of the proposed feature. [Reference RTL](scalar_memory_review.sv) · [Reproduction script](test_phase2_semantic_references.ps1) · [Windows results](../../evidence/p23-scalar-memory/qualification.json)

### Transition construction

The internal exact-memory builder emits one next-state equation per cell and one for the read target. It accepts normalized unsigned addresses and resolves the read through a balanced tree over the declared cells. Each enabled write compares its address with the cell's numeric index. The successor holds for a disabled write or a nonmatching index. The builder exposes each access's range condition as a separate predicate so the proof manager can discharge it before publishing a regular property result.

The component regression checks both zero-based and offset three-cell memories and the largest 64-bit address. It checks all read/write enable and address combinations against an independent transition oracle, verifies that each wrong successor bit is unsatisfiable, and replays the oracle traces. The symbolic variant also proves successor consistency for arbitrary initial cell values and data across 128 address and enable combinations. The next integration binds the predicates to proof obligations and lowers declarations and accesses from the agreed Register-Transfer Level (RTL) profile. [Component test](test_state_transition.ps1) · [Result](../../evidence/r-p2-state-core-symbolic/qualification.json)

### Range certificate qualification

The verified transition component now generates two same-sample assertions from a memory's read and write predicates. Both keep the source access location. The labels must be distinct and available in the model's property table. In the integration fixture, the read bound follows from a separately declared upstream assumption. The write bound follows from the design's enable decoder.

Property Directed Reachability (PDR) discharged both assertions and reopened their certificates from the same transition model. The standalone checker accepted the six Deletion Resolution Asymmetric Tautology (DRAT) obligations. Removing the upstream assumption or the write decoder exposed a sample-zero access at address 3 for a three-word memory. Boolean Satisfiability (SAT) supplied both witnesses, and the independent replay path reproduced them. Each original certificate rejected the changed access context.

Source declarations, range proof orchestration for normal product commands, and linking the guard certificates to the primary result remain in the profile integration. [Component test](test_state_transition.ps1) · [Certificate results](../../evidence/r-p2-range-checked/qualification.json)

### Development source path

A development-only parser mode preserves module-scope unpacked index ranges and source locations. The elaborator resolves parameterized bounds and keeps the direction of the declaration. A source-to-transition component accepts an isolated top module with one array, one positive-edge process, a guarded indexed write and a guarded indexed read into a registered output. It lowers nonblocking accesses through the exact memory builder and emits both range assertions from their source locations. The caller supplies the cell budget.

The source test proves the range assertions for a four-word memory in either declaration direction and replays a simultaneous read and write to the same address. An override that shifts the first address to 1 exposes address 0 in both range checks. The released parser retains its original diagnostic. Extending source admission to ordinary module composition and binding checked range certificates to primary CLI results remain production integration work. [Source test](test_state_transition.ps1) · [Windows evidence](../../evidence/p2-memory-source-build/qualification.json)

### Internal proof group

An internal proof entry point takes a source-derived transition model and a primary safety assertion. It searches the generated read assertion, the generated write assertion, and the primary assertion in that order with one environment. After the three searches find invariants, each certificate is independently checked in a private staging directory beside the requested destination. The final group appears through a single Windows directory move after all three certificates pass. An interruption before the move discards staged certificates during normal error handling. A competing destination is preserved. Reopening regenerates the three sets of Property Directed Reachability (PDR) obligations from the source-derived model and checks the read and write certificates before the primary certificate. The saved certificate layout remains the same.

The development entry point compiles in-module named and inline SystemVerilog Assertions (SVA) using the shared compiler. Property operands resolve against source-visible scalar ports and elaborated constants. The compiler retains historical values and validity guards for supported temporal expressions. The product command still needs the agreed source admission rules. The source proof group regression supplies one valid and one false primary assertion, checks separate invalid reads and writes, and attempts reopen with a missing certificate and a changed source bound. [Proof group regression](test_state_transition.ps1) · [Source assertion and certificate evidence](../../evidence/r-p2-memory-sva/qualification.json)

The Windows fault-injection regression interrupted the operation after the first certificate was checked, then separately created a competing destination after the third certificate was checked. In both cases the requested group was left unpublished, and the staging files were cleared. The competing destination retained its original marker. [Publication regression](test_state_transition.ps1) · [Component qualification](../../evidence/p2-memory-group-atomic-component-final/qualification.json) · [Windows CLI and long-path qualification](../../evidence/p2-memory-group-atomic-final/qualification.json)

### Development command line

Build a separate Windows executable with `-EnableDevelopmentMemory`. Provide a normal project manifest, one source translation unit, a named assertion, the evidence directory, and a cell budget. The normal preprocessing path resolves includes and applies manifest parameters. Reopen takes the same manifest and property. It rebuilds the transition model and checks all three certificates against the exact manifest, source set, and profile.

```powershell
.\prototype\source\source_manager\build.ps1 -EnableDevelopmentMemory -Output evidence/memory-dev/q3aformal-sourcecheck.exe
$exe = '.\evidence\memory-dev\q3aformal-sourcecheck.exe'
& $exe dev-prove-memory project.q3a --property p_hold --output-dir memory-proof --max-cells 4
& $exe dev-verify-memory project.q3a --property p_hold --evidence-dir memory-proof --max-cells 4
```

Both commands accept `--timeout-ms`, `--memory-mib`, and `--cancel-file`. Search also accepts `--max-depth` and `--max-queries`. The JSON result identifies the property, profile, source set, manifest, and combined model input. A proved group reports `PROVEN`; successful reopen reports `REVALIDATED`. An unproved access or primary assertion reports the first unresolved target. The command-line regression checked changed include and manifest bytes, wrong property selection, missing evidence, cancellation, and separate development and release binaries. [Command regression](test_memory_cli.ps1) · [Windows evidence](../../evidence/p2-memory-cli-development/qualification.json)

### Assumption feasibility and assertion activation

Both address checks and the primary proof use the same model and declared assumption environment. An unsatisfiable finite environment query returns `INCONSISTENT` with the bound that exposed it. The command leaves the proof destination unpublished.

Add `--activation-frames N` to prove or reopen a memory certificate group with bounded assertion activation analysis. The value N is the number of transitions and can be zero through 128. The analysis tests whether the assertion was eligible to evaluate in the bounded environment, including history guards and the complete property horizon. The replay evaluator independently checks a candidate activation.

- `ACTIVATED` identifies a replayed eligible sample. The JSON includes the sample and bound.
- `PENDING_ASSUMPTION` identifies an eligible sample in a prefix with a future assumption boundary.
- `NOT_FOUND_WITHIN_BOUND` records a bounded miss. An unreachable antecedent requires an unbounded proof of non-activation.
- `UNKNOWN` records an inconclusive activation search.

On certificate reopen the tool recomputes the requested activation check from the supplied source and bound. The staged build passed five activation cases, rejected contradictory environments at bounds zero and one, and reopened an existing preview certificate. The cross-engine oracle checked 80 results for the shared replay path. [Staged build evidence](../../evidence/p2-memory-activation/qualification.json)

### Range diagnostics

Add `--diagnose-range` to `dev-prove-memory` to examine a range counterexample candidate. If bounded reconstruction succeeds, `range_witness` records the first invalid frame along that reconstructed trace. It reports every invalid read or write at that frame, including its source file, line and column, address signal, sampled address, and legal interval. The address and interval bounds are decimal strings, preserving all unsigned address bits.

The independent evaluator replays the trace prefix through the failing sample. Both generated guards must hold on every earlier sample of that trace, so replay does not depend on unspecified out-of-range read data. A diagnostic with `boundary_incomplete` set carries a finite-prefix result under an environment with a future assumption boundary. The command retains `RANGE_UNPROVED` and leaves the certificate destination unpublished.

The regression checks invalid reads, invalid writes, both accesses at one sample, and the provisional result under a temporal assumption. A component test forces a legal transition before the first invalid read. Existing memory commands and archived proof groups remain compatible. [Diagnostic regression](test_memory_range_diagnostics.ps1) · [Windows qualification](../../evidence/p2-memory-range-diagnostics/qualification.json)

### Save and reopen a range trace

Supply `--range-trace FILE` to save the replayed prefix in indexed form. The file commits only after the prefix has passed replay. Choose an unused file path in an existing directory. The trace binds the exact lowered model, source set, manifest and requested property. It contains the legal prefix and the first invalid-access sample.

```
& $exe dev-prove-memory project.q3a --property p_hold --output-dir unused-proof --max-cells 4 --range-trace invalid-access.q3t
& $exe dev-verify-memory-range project.q3a --property p_hold --trace invalid-access.q3t --max-cells 4
```

On reopen the engine rebuilds the model from the project and checks the indexed frame dictionary, transition equations, assumptions, both range checks, and the final failing sample. A complete prefix returns `RANGE_WITNESS_REVALIDATED`. A prefix with a future assumption boundary returns `RANGE_WITNESS_PENDING_ASSUMPTION` with exit code 1. The proof output directory is unused when range proof fails.

Windows qualification reopened three complete traces and one provisional trace. It rejected changed source, a different requested property, a truncated file, and a structurally valid trace with an earlier invalid access. A separate test saved and reopened a trace at a 339-character path. [Windows qualification](../../evidence/p2-memory-range-trace/qualification.json)

### Native Windows range viewer

Open a saved range trace with the same project and requested property.

```powershell
& $exe dev-gui-memory-range project.q3a --property p_hold --trace invalid-access.q3t --max-cells 4
```

The viewer checks replay before opening. It starts at the first invalid sample and highlights the failing statement in the Register-Transfer Level (RTL) source. The run panel lists each invalid address and its allowed interval at that sample. Invalid access controls are selected automatically, together with a preview of the stored state. For a prefix with an incomplete temporal assumption, the cursor summary identifies the provisional status. A saved viewer session binds the trace bytes.

Three native sessions qualified read, simultaneous read/write and provisional traces. The source highlight, invalid-access signal group, cursor, marker and saved session were checked. The standard native viewer and development multi-clock viewer also passed their regressions. [Windows qualification](../../evidence/p2-memory-range-gui-dev/qualification.json)

### Memory limits during model construction

Both memory commands apply the existing process-private memory limit and host reserve while creating the exact transition model. The frontend checks the pending vector reservation before allocating cell descriptors and equations. It polls the same budget and cancellation callback during cell creation, write-equation construction and balanced read-tree construction. If the budget cannot admit the reservation, the command returns `RESOURCE_LIMIT` before writing a proof group. `--max-cells` remains the separate bound on the declared array size.

A Windows functional test with 1,048,576 declared cells rejected a 168 MiB cell-vector reservation under a 16 MiB process limit. A separate case rejected the declaration by cell count. A component test injected interruption during the read-tree construction. The updated engine still revalidated the earlier scalar-memory proof and passed subsystem functional preflight. [Resource regression](test_memory_lowering_budget.ps1) · [Windows qualification](../../evidence/p2-memory-lowering-budget/qualification.json)

### Same-clock scalar controls

The development memory compiler can combine its exact array transition with ordinary scalar and packed logic in the same flat module. Read and write enables, addresses and write data can come from the module's inputs, combinational equations, or registered scalar state. The array still has one guarded nonblocking read and one guarded nonblocking write in their own process. Its addresses remain unsigned and each operand is a signal name. Scalar helper registers must use the memory's positive-edge clock. The compiler rejects undriven helper signals and separate processes that access the same array.

The ordinary lowerer handles scalar control equations, with the registered memory output treated as an external signal during that step. The combined model restores its exact read-old transition and checks both address ranges before certifying the requested temporal assertion. Sampled properties can refer to the declared control signals and read data. Additional array processes, array access inside an unrelated control process, multiple clocks, and hierarchy remain outside this profile.

The Windows development build proved read-back after a preceding accepted write and output hold when reading is disabled. Both proof groups reopened from the source. The independent checker accepted nine obligations. Invalid read, invalid write and incorrect data each stopped certification. Different clocks, floating controls and a second memory-access process were rejected. The same executable reopened a previously issued memory certificate and passed the legacy memory, clock-event and subsystem preflight suites. [Focused regression](test_memory_scalar_control.ps1) · [Windows qualification](../../evidence/p2-memory-scalar-integration/qualification.json)

## Sequential equivalence

Construct a product transition system with one reference model, one implementation model, shared external inputs, and an explicit observation relation. Use the same clock schedule and sampled environment on both sides. Bind port widths, signedness, clock domains, reset polarity, and observation latency by name and mapping. A mismatch in one mapping invalidates the proof identity.

Initial-state treatment is an engineering decision with three distinct scopes.

| Scope | Proof obligation |
| --- | --- |
| All permitted initial pairs | Show output agreement under the independent initial-state policies and common environment. |
| State correspondence | Prove the correspondence is an invariant for the declared initial pairs and the two transition relations. |
| After reset | Prove reset reachability or apply an explicit reviewed input condition for reset delivery. Show that the agreed observation enable starts only after both models satisfy the declared reset condition. |

A matching internal signal name supplies a candidate relation. The checker must establish initialization and preservation before using it as a lemma. Keep the reference and implementation source hashes, the shared input binding, state relation, and output observations in the certificate. A failure must replay in both exact models with the same inputs and publish both observed values. An unmatched proof budget remains inconclusive. Prove native equivalence only after the state-matching and composition contracts are approved. [Proof composition review](proof-composition-review.md)

## Required checks

1. Exact memory cells agree with the independent oracle at legal addresses, including read-old collision, an off-domain hold, and an uninitialized address read.
2. A non-power-of-two depth rejects an enabled invalid address. Proof and replay reject changed width, collision policy, local clock, or range evidence.
3. Equivalent state encodings with different internal state names pass under a checked relation. A missing initialization proof and a representative one-cycle observation mismatch fail the appropriate obligation.
4. A sampled paired witness replays in both models. Tampered inputs, observation masks, latency, or certificate identity are rejected.
5. Compare exact and any later abstract encoding at small depth before scaling. Larger examples record wall time, peak memory, solver outcome, and the limits approved for that workload.

[Finite-state memory and paired-model oracle](memory_equivalence_oracle.py) · [Multi-clock scheduling review](multi-clock-scheduling-review.md)

## Glossary

| Term | Meaning |
| --- | --- |
| Collision | A read and write to the same legal address in one sample. |
| Product transition system | Joint reference and implementation state updated using the shared input contract. |
| Read-old | A collision returns the addressed cell's pre-state value at a synchronous read. |
| RTL | Register-Transfer Level hardware description. |
| T-IR | Transition Intermediate Representation. |


## Q3AFormal equivalence plan

The one-clock product model preserves each design's state and driving equations. It identifies common inputs through a complete, one-to-one port map and compares every mapped output at the same sampled edge. Internal states have separate namespaces. The mapping checks port direction, width, signedness and packed bounds. The scope is selected in the plan.

```text
Q3AFORMAL_EQUIVALENCE 1
clock clk clock
input rst reset
input d value
output y result
reset rst high
```

The reset rule refers to the reference-side name of a mapped one-bit input. It constrains the first sample to the indicated reset level and begins observation at the next sample. After the first edge, shared inputs follow the ordinary source transition model and can include any permitted reset sequence. The proof must establish equality after that edge for every pair of unconstrained starting design states. Replacing the reset rule with `initial independent` compares from sample zero. In that scope, different possible values of uninitialized outputs can be a valid mismatch even for identical transition functions.

```powershell
.\q3aformal-sourcecheck.exe check-equivalence ref.q3a imp.q3a --plan pair.q3e --output-dir evidence
.\q3aformal-sourcecheck.exe verify-equivalence ref.q3a imp.q3a --plan pair.q3e --evidence-dir evidence
```

Both commands accept `--timeout-ms N`, `--memory-mib N` and `--cancel-file PATH`. The check command also accepts `--max-depth N` for Property Directed Reachability (PDR) search. A checked invariant has separate initiation, consecution and safety artifacts. A mismatch has a trace validated by the independent Register-Transfer Level (RTL) replay evaluator against both transition models with common input values. Reopening rebuilds the exact product model and checks the trace or certificate. The trace is bound to the mapping and both source projects, and the mismatch report names both observed ports and values.

This version covers zero observation latency on the one-clock, two-valued profile under the common plan environment. Source files containing assumptions require an explicit common-assumption contract for a later version. The optional state checks described below establish correspondence under either supported start scope. The matched-initial scope below also supports explicit initial-pair constraints.

## Windows candidate qualification

The candidate proved two sequential implementations with different internal state encodings and port names under a first-edge reset. Both active-high and active-low cases passed. The independent-initial-state scope proved a combinational pair and exposed a sample-zero mismatch for the uninitialized sequential pair. A changed update and an additional register stage both produced a sample-two mismatch. The replay evaluator revalidated the paired witnesses from both RTL projects with common inputs.

The standalone proof checker accepted all nine obligations for the three positive models. Verification rejected an incomplete or incompatible port map, a changed reset scope, altered RTL, a swapped proof, and an altered witness. After refreshing the witness checksum, withdrawing the promised reset still failed semantic replay. The same executable passed the previous composition, parallel batch and strict source replay regressions. [Main qualification](../../evidence/r-p2-equivalence/qualification.json) · [Standalone proof and active-low checks](../../evidence/r-p2-equivalence-low/qualification.json)

## Declared state correspondence

Add optional `state REFERENCE_REGISTER IMPLEMENTATION_REGISTER equal|invert` lines to the equivalence plan. Each side resolves to a driven state signal. The two declarations must agree on width, signedness and packed bounds. For example, `state y encoded invert` requests a bitwise-complement relation for two equally typed registers.

Q3AFormal generates a separate assertion for the conjunction of these relations and checks it on the paired, source-derived transition system. Both certificates use the same original environment. With a first-edge reset, the relation must hold from sample 1. With independent initial states, the relation must hold from sample 0 without imposing an implicit pairing.

A relation failure reports `STATE_RELATION_VIOLATED` and saves `state-witness.txt`. A violation at the first observed sample is labeled `STATE_INITIALIZATION`. A later violation is labeled `STATE_PRESERVATION`. The witness contains the common inputs and both state trajectories for independent replay. The command checks output equivalence only after the state-relation certificate is accepted. Verification requires every certificate needed by the stored verdict.

On the Windows candidate, two-bit equal and inverted relations produced independent state and output certificates. A wrong reset relation was replayed at sample 1. A corrupted later update failed at sample 2 while the output-only check still proved equivalence. A separate output mutation failed at sample 1 after its state certificate had passed. The verifier rejected missing and substituted state evidence. All twelve standalone proof obligations passed. Prior output-only proof and witness artifacts reopened on the same candidate. [Integration evidence](../../evidence/r-p2-state-relation/qualification.json) · [Standalone checks](../../evidence/r-p2-state-relation/standalone-all.json)

## Explicit initial-state pairs

Use `initial matched` and at least one `state` directive to restrict the allowed pairs at sample 0. Each equality or bitwise inversion in the plan participates in the initial relation. Unmapped state remains unconstrained. The initial relation is an explicit premise of the result and the report labels the scope `MATCHED_INITIAL_STATES`. Outputs are compared from sample 0. An initialized one-step flag disables the initial relation as an environment constraint after sample 0. The separate state assertion must then be proved for every reachable sample.

The Windows candidate accepted all six standalone proof obligations for the two-bit matched-start example. A faulty transition violated the relation at sample 1, and wrong output logic produced a sample-zero mismatch after the state proof passed. An altered witness with a refreshed checksum still failed replay when its initial pair violated the plan. The existing reset and independent-start regressions passed on the same executable. [Matched-initial integration evidence](../../evidence/r-p2-matched-initial/qualification.json)

## Equivalence debug waveforms

A replay-validated output mismatch saves `paired-witness.txt` and `paired-witness.vcd`. A state correspondence mismatch saves the analogous `state-witness.txt` and `state-witness.vcd`. The Value Change Dump (VCD) groups common inputs under `shared`, preserves the separate `reference` and `implementation` scopes, and raises `__q3a_diagnostic.failure_sample` at the reported sample. Each timestamp is one abstract verification sample.

The VCD uses the ordinary witness exporter and can open in the offline trace viewer. Reopening a version 2 paired witness rebuilds both models, replays the stored samples, then compares the waveform with a deterministic export of those samples. Version 1 text-only witnesses retain source-required replay support.

```powershell
.\q3aformal-sourcecheck.exe trace view-vcd evidence/paired-witness.vcd > paired-waveform.html
```

The Windows test imported both mismatch types through the ordinary VCD parser and generated the offline waveform pages. Both pages carry a sample-2 marker and preserve the two observed values reported by the source-backed witness. Verification rejected a changed marker and a missing version 2 waveform. The previous text-only witness and legacy VCD regression passed. [Waveform qualification](../../evidence/r-paired-wave/qualification.json)
