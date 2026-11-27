# Q3AFormal Phase 2 Multi-Clock Scheduling Review

This semantic design is proposed for owner review. The Phase 1 profile continues to use single-clock execution. A multi-clock profile requires separate approval and implementation evidence.

## Current implementation boundary

The Transition Intermediate Representation (T-IR) stores the design clocks and each property's sampling clock. The development adapter also records each next-state equation's owning clock during Register-Transfer Level (RTL) lowering. The bounded Boolean Satisfiability (SAT) transition encoder validates the property against the module's single clock and encodes a synchronous step. Lowering, unrolling, induction, Property Directed Reachability (PDR), replay, and the waveform currently share that interpretation of a sample. A clock-name list alone cannot specify a legal multi-clock transition, sampling alignment, or archived proof identity. [T-IR](../../prototype/source/lowering/lowering.hpp) · [Transition encoder](../../prototype/source/sat/transition_encoder.cpp) · [Development roadmap](../../../Q3AFORMAL_SPECIFICATION.md#163-phase-2--subsystem-scalability)

## Proposed transition system

Let `D` be a fixed, ordered set of supported edge domains and `e_t ∈ {0,1}^|D|` the event mask at global step `t`. The scheduler contributes a legality predicate `L(Q_t, e_t)` and an update `Q_{t+1} = next(Q_t,e_t)` over scheduler state `Q`. The hardware transition collects combinational values from the same pre-state and sampled inputs `U_t`. Each register's update uses its owning domain's edge bit. All enabled registers commit simultaneously.

```text
I(S0,Q0,H0) = RTL initial policy ∧ scheduler initial condition ∧ history-valid initialization
T = L(Q,e) ∧ Q' = next(Q,e) ∧ RegisterUpdate(S,U,e,S') ∧ MonitorUpdate(H,S,U,e,H')

For register x owned by domain d:
  x' = x                         if e[d] is 0
  x' = reset_value(x)            if e[d] is 1 and its synchronous reset is asserted
  x' = next_value(x,S,U)          otherwise
```

All right-hand sides use `S` and `U` from the same pre-step observation. A same-step pair of domain events cannot be expanded into two serial writes. An example with registers `x←y` and `y←x` starts at `(0,1)`. A joint edge reaches `(1,0)`. Serializing it reaches `(1,1)` or `(0,0)`. The three outcomes must remain distinct. The SystemVerilog language standard remains the authority for the subset's observation and update rules. This scheduler defines the proposed formal abstraction for that subset. [IEEE 1800-2023](https://standards.ieee.org/ieee/1800/7743/)

The initial scheduler proposal accepts any declared event mask, including no-edge steps. A no-edge step holds domain-local registers and monitors. Global inputs may still vary within the documented environment constraints. Any future removal of no-edge steps must preserve the supported observation semantics and all environment assumptions. This first proposal expresses no frequency, phase, duty cycle, or fairness guarantee.

An optional exact periodic scheduler could encode independent finite phase counters and derive the joint mask at each quantum. Its proof identity must bind periods, phase offsets, quantum, initial phase and input sampling. Clock ratios and schedules must come from an explicit contract. They must never be inferred from signal names. Avoid replacing simultaneous schedules with a reduced interleaving schedule without a preservation proof for the supported property and environment. Peled's reduction relies on a documented independence relation and equivalence-robust properties, so it provides a review reference for a later optimization. [Peled, *All from One, One for All*](https://ai.dmi.unibas.ch/research/reading_group/peled-cav1993.pdf)

## Property and history alignment

- Each accepted SystemVerilog Assertion (SVA) property has one explicitly bound sampling domain. A `##n` delay counts samples of that domain. A step on another domain neither starts nor advances that monitor.
- A guarded `$past(expr,n)` reads the `n`th prior sampled value of the property's domain and uses the existing history-valid policy. The monitor samples before enabled updates commit. A simultaneous event updates all participating monitors from the same pre-state.
- Synchronous reset affects a register only on its domain event. History-reset behavior must follow the separately reviewed property contract. Cross-domain sequence composition, asynchronous reset, clock generator logic, fairness, and analog metastability require separate semantics and evidence.
- Each counterexample includes the global step index, event mask, effective sampled inputs, post-state, and the domain-local sample index where a property fires. Replay must reject a mismatched event mask, scheduler state, owner domain, sampling index, or archived configuration digest.

The event-mask model assigns event bits to domain controls. Signals declared as clocks need a diagnostic if they are also read as ordinary Boolean data or used to compute another clock. A free event bit does not encode a sampled clock level, so those reads need a future level-and-edge relationship. Assumptions declared on a domain advance only on that domain's events, including when both domains are active. Record the schedule and assumption policy in the model identity and show that the fixed, always-active single-domain schedule preserves the existing behavior.

## Integration and proof obligations

| Component | Proposed change and retained check |
| --- | --- |
| Project manifest and elaboration | Preserve legacy manifests. Add an opt-in, versioned scheduler contract and fail closed on ambiguous domain ownership or unsupported event controls. |
| T-IR and lowering | Bind each register update and property monitor to a declared domain. Keep pre-state sampling explicit. Version the transition model and retain source spans on bindings. |
| SAT, induction, and PDR | Use the same one-step relation in bounded unrolling, induction checks and PDR initiation, consecution, and safety obligations. PDR can reuse its Boolean transition-system interface after the relation, monitor, and scheduler state are independently checked. [Bradley, *SAT-Based Model Checking Without Unrolling*](https://theory.stanford.edu/~arbrad/papers/IC3.pdf) |
| Replay, bundle and waveform | Replay the legal schedule independently. Bind scheduler, clock bindings and monitor semantics to proof/cache identities. Retain domain-local sample indices and show simultaneous events at one global step. Legacy trace formats remain readable. |
| Boundary contracts and memory | Preserve the global event mask when partitioning. Every imported guarantee needs a checked discharge obligation under the same scheduler. Memory or equivalence support requires its own review of collision, reset, state matching, and proof composition semantics. |

A scheduler over-approximation can prove safety for its covered schedules when every concrete transition maps to a modeled transition. A failing trace is a counterexample to the declared scheduler model. A result under a weaker scheduler may require an additional witness feasibility check against a stricter user clock contract. Proof output must carry this domain of validity. The model does not assign an analog interpretation to asynchronous clock-domain crossings.

## Scalar reference qualification

A single supported global clock drives two register domains controlled by independent mask bits. Property Directed Reachability (PDR) proved both register holds, both sampled resets, simultaneous pre-state reads, and the update and hold rules for an explicit two-entry domain-local history. A cover run reached a swap of distinct register values. Two mutations produced counterexamples for serializing a joint edge and advancing history on the peer domain alone. All three witnesses reopened from source. The standalone checker accepted 21 Deletion Resolution Asymmetric Tautology (DRAT) obligations, three per proof.

The fixture implements its history registers with ordinary Register-Transfer Level (RTL) statements. The production scheduler, domain-local SystemVerilog Assertions (SVA) compilation, and multi-clock replay retain the requirements above. [Reference RTL](scalar_clock_review.sv) · [Reproduction script](test_phase2_semantic_references.ps1) · [Windows results](../../evidence/p23-scalar-clock/qualification.json)

The internal sampled-assignment builder emits an ordinary typed next-state equation with an explicit one-bit enable. The inactive branch references the target's pre-state. The component test checks each pair of state bits and event bits against the same-step update in the transition encoder and replay evaluator. It establishes the equation primitive used by the scheduler. Domain binding, compiled property monitors, and the public scheduler contract are separate implementation steps. [Component test](test_state_transition.ps1) · [Result](../../evidence/r-p2-state-core-symbolic/qualification.json)

## Development RTL scheduling

The source adapter captures the owner of every next-state equation from its positive-edge process. After ordinary scalar RTL lowering, it removes source clock level ports from the formal data frame, exposes one event input per domain and guards each state update with that input. Each equation reads the common pre-state. Combinational equations continue to evaluate from each frame. The development model uses the profile identifier `Q3A-FREE-EVENT-MASK-DEVELOPMENT`.

The reference fixture uses two peer-sampling registers with independent synchronous resets and a combinational status output. The test checks the full cross product of both pre-state bits, both reset inputs, and both event inputs. It checks replay rejection after changing one edge in a simultaneous update and checks diagnostics for clock-as-data and multiple drivers. Domain-local assertion sampling, versioned project admission, and persisted trace metadata remain for further integration. [Source regression](test_state_transition.ps1) · [Windows evidence](../../evidence/p2-event-mask-build/qualification.json)

## Development domain-local assertions

The development source compiler groups checks by their declared sampling clock. It uses the existing SystemVerilog Assertions (SVA) compiler separately for each domain and binds generated history registers and validity flags to that domain's event bit. A same-sample assertion or assumption is active on its own edge. A cover requires that edge to hit. Multiple predicates separated by zero-cycle delays are conjoined at the same sample.

The source test proved assertions using one- and two-sample histories and checked all six obligations with the standalone checker. It also found a false assertion, demonstrated that a peer-only event leaves another domain's assumption inactive, and rejected a cover replay after removing its edge. The initial regression qualified the same-sample cases. [Component regression](test_state_transition.ps1) · [Windows qualification](../../evidence/p2-event-domain-sva-build/qualification.json)

## Development domain-local sequences

The single-clock proof engine and development event adapter share the finite sequence monitor compiler. The event adapter gates both delay-line updates and property decisions with the owning domain's event bit. Fixed and ranged delays, positive bounded repetition, and overlapped and nonoverlapped implication reuse the same finite monitor semantics. Generated state bits hold through idle global steps and peer-only events. The current monitor implementation bounds the maximum source sequence offset to 128 local samples.

The source regression checked both endpoints of a one-to-two-sample range while inserting peer and idle steps. It also checked that an assumption obligation is applied at its next local sample, replayed the cover witnesses, and rejected a changed event. Four certified source assertions include both implication alignments and one- and two-deep history checks. Public bounded-result reporting still needs the original obligation boundaries and product trace integration. [Source regression](test_state_transition.ps1) · [Windows qualification](../../evidence/p2-event-delay-build/qualification.json)

## Development indexed event witness

The indexed trace stores values by global step. Its schedule sidecar binds the original source model, clock and state ownership maps, selected property, and global candidate. A step lists the zero-based sample index of each active clock in dictionary order. An inactive clock contributes a dash. Reopen independently checks the transition and property witness and compares the recorded schedule with canonical rows regenerated from indexed values. It can reject a changed schedule without loading the entire sidecar.

Two 321-step cover artifacts retained clock A's samples 1 and 2 at global steps 318 and 320, with idle and peer-domain events in the trace. The regression also reopened an assertion counterexample and rejected changes to source bytes, index, edge mask and trailing metadata. [Component regression](test_state_transition.ps1) · [Windows qualification](../../evidence/p2-event-witness-build/qualification.json)

## Development bounded event windows

The finite monitor preserves an indicator for obligations still in flight at the end of a global window. It includes obligations launched on the final local edge and intermediate delay stages. The final stage remains open without its owning edge. A final edge that consumes it can instead decide the corresponding condition. A peer edge leaves it in flight.

The bounded classifier separates a completed witness, a feasible closed window without a witness, a window with a reachable open obligation, an inconsistent environment, and a solver result without a conclusion. A completed cover or counterexample also records whether the chosen trace has an unfinished assumption. For ranged alternatives, the pending indicator conservatively records reachable active alternatives. The closed-window result applies only to the supplied finite global prefix. Public result packaging and command admission remain separate integration work. [Component regression](test_state_transition.ps1) · [Windows qualification](../../evidence/p2-event-window-build/qualification.json)

## Development event commands

Build a separate executable with `-EnableDevelopmentEventMask`. The command accepts the normal project manifest and elaborates it under the development event profile. The `--frames` value sets the number of global transitions. For example, zero transitions includes one sampled frame. Independent positive edges, idle steps and same-step edges are permitted in the free event model.

```powershell
.\prototype\source\source_manager\build.ps1 -EnableDevelopmentEventMask -Output evidence/event-dev/q3aformal-sourcecheck.exe
$exe = '.\evidence\event-dev\q3aformal-sourcecheck.exe'
& $exe dev-check-events project.q3a --property c_hit --output-dir event-witness --frames 20
& $exe dev-verify-events project.q3a --property c_hit --evidence-dir event-witness
```

The commands accept `--timeout-ms`, `--memory-mib`, and `--cancel-file`. A witness creates an indexed trace and a schedule file in a new directory. The JSON result includes the global frame and the zero-based local sample when a witness exists. If a witness has an unfinished assumption at the window boundary, both operations retain `WITNESS_PENDING_ASSUMPTION` and exit code 1 even after successful replay. A finite window with no witness reports `BOUNDED_COMPLETE` or `BOUNDED_INCOMPLETE` and exits with code 1. The release build continues to use its approved one-clock profile. [CLI tests](test_event_cli.ps1) · [Windows qualification](../../evidence/p2-event-proof-development-final/qualification.json)

Unbounded safety and unreachability use the same source profile and the Property Directed Reachability (PDR) engine. Use `dev-prove-events` and `dev-verify-event-proof` to create and check a certificate. Both require the exact manifest, source set and selected property. PDR search additionally accepts `--max-depth`, `--max-queries` and `--feasibility-frames`. A proof contains checked initiation, consecution and safety obligations and the originating run configuration. A counterexample or a cover hit goes through the bounded replay path and reopens with `dev-verify-events`. The safety proof quantifies over free event masks and has no fairness assumption.

```powershell
& $exe dev-prove-events project.q3a --property p_safe --output-dir event-proof --max-depth 32
& $exe dev-verify-event-proof project.q3a --property p_safe --evidence-dir event-proof
```

## Native Windows event trace viewer

Open a bounded or unbounded witness with the same project manifest and property that produced it.

```powershell
& $exe dev-gui-events project.q3a --property c_hit --evidence-dir event-witness
```

The viewer replays the indexed trace and checks the schedule against the elaborated source before opening. Its run panel shows the current global step, each clock's zero-based local sample, and idle clocks. The Clock edges group shows the sampled event mask. Source navigation, markers, signal groups and session saving work in the same window. A saved session is bound to the verified trace and schedule. A witness with an unfinished assumption remains provisional. The viewer is available with the development build flag. [CLI and native window tests](test_event_cli.ps1) · [Windows qualification](../../evidence/p2-event-gui-development/qualification.json)

## Review and acceptance checklist

1. Approve the event-mask semantics, no-edge behavior, reset and history rules, and the initial accepted SVA profile. Approve periodic scheduling separately if needed.
2. Compare the two-domain oracle with SAT encoding and independent witness replay. Test simultaneous and consecutive edges, unequal domain rates, reset ignored off-domain, holds during idle steps, domain-local history, and rejection of cross-domain event syntax.
3. Prove the single-domain fixed-edge embedding is equivalent to the released Phase 1 transition and property sampling on the supported corpus. Keep released bundles readable through the normal commands.
4. Check safety-true, safety-false, cover-hit and cover-miss examples. Reject a deliberately changed scheduler or domain mapping when revalidating a checked certificate. Use actual checker results for initiation, consecution and safety.
5. Measure subsystem scalability only after numeric limits and frozen workloads are approved. Keep resource exhaustion inconclusive and retain exact benchmark identities.

[Executable finite-state review oracle](clock_schedule_oracle.py)

## Glossary

| Term | Meaning |
| --- | --- |
| Event mask | Bit vector identifying the domains whose configured edge occurs on a global step. |
| Global step | One scheduler transition and its atomic set of simultaneous hardware updates. |
| Domain-local sample | A property observation counted only on events in that property's sampling domain. |
| PDR | Property Directed Reachability, which proves safety using inductive reachability information. |
| RTL | Register-Transfer Level hardware description. |
| SAT | Boolean Satisfiability, the decision problem for Boolean formulas. |
| SVA | SystemVerilog Assertions. |
| T-IR | Transition Intermediate Representation. |

