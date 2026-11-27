# Q3AFormal Phase 2 Proof Composition Review

This proof contract is proposed for subsystem scalability. Composed proof results require implementation and independent checker evidence.

## Recommended first implementation

Use a directed acyclic graph of safety guarantees. Each partition has a projected model with explicit cut inputs. An internal assumption may consume an already checked guarantee along a declared dependency edge. Product inputs and constraints belong to the named environment contract. The proof report must identify the scope of that contract. This workflow follows the assumption-discharge principle of assume–guarantee reasoning. [Cobleigh, Giannakopoulou, and Păsăreanu, *Learning Assumptions for Compositional Verification*](https://ntrs.nasa.gov/citations/20030017771)

Given a concrete system with initial predicate (I), transition relation (T), and reviewed environment monitor (E), retain one state projection (π_i) and one cut representation (κ_i) per partition. The checker must establish all four evidence classes.

| Obligation | Required evidence |
| --- | --- |
| Initial projection | Every concrete initial state allowed by (E) maps to a valid local initial state. |
| Transition projection | Every concrete legal step maps to a local step through the recorded cut values and scheduler event mask. A local model may admit additional behaviors. |
| Internal assumption discharge | For each imported boundary predicate, the checked producer guarantee and wiring map imply the consumer assumption on the same sampled boundary value. Supplier proofs must precede the consumer in the dependency graph. |
| Property discharge | Under the approved environment, the checked guarantees imply the global safety assertion. The checker must verify the implication for the symbol and sampling scopes used by that assertion. |

A local guarantee includes its induction evidence. Initiation and consecution must establish the complete claimed guarantee, or an inductive strengthening that implies it. The checker must retain the local model's identity and validate the exact property. An inconclusive local result, missing producer certificate, or failed projection prevents an unconditional top-level proof.

Export the safety guarantee at the same observation point consumed by dependent partitions. A proposition on the producer's next state cannot discharge an assumption on its current state unless a separate temporal alignment obligation establishes it. An input owned by the environment and an internal cut driven by the design require distinct contract treatment.

## Certificate and result model

Reuse the existing checked Deletion Resolution Asymmetric Tautology (DRAT) format for each Boolean Satisfiability (SAT) query. Add a versioned composition manifest that identifies the global model and wiring, partitions, boundary polarity and bit ranges, scheduler interpretation, global and local assumptions, local property monitors, all dependency edges and evidence digests. The independent checker regenerates each obligation's query from the actual binding and requires a checked artifact against that query's exact digest. A proof cache key must include the composition scope, consumed certificates and explicit scheduler semantics.

A tentative failing trace from an over-approximate local model must be replayed on the original subsystem and legal schedule before reporting a system failure. A cut trace with no concrete replay may guide refinement. A top-level limit or unresolved dependency remains inconclusive. Verify environment feasibility separately and preserve any constrained proof scope on export.

## Why start with an acyclic graph

Acyclic dependencies make the induction over checked guarantees explicit and let the checker verify in graph order. An apparent proof such as (x=0) under (y=0) and (y=0) under (x=0) can pass local implication checks while an allowed global initial state is ((1,1)). Reject cyclic dependencies in the initial profile. A later circular-proof format needs checked global initiation and checked joint consecution of a simultaneous invariant. More advanced circular liveness reasoning requires a separate semantics review. [McMillan, publication index](https://mcmil.net/pubs/)

## Acceptance cases

1. A producer guarantee discharges a consumer assumption. The composed result agrees with an independent finite-state exploration.
2. Mutating the producer allows a concrete counterexample and fails assumption discharge. A mismatched wiring map or bit polarity fails projection or discharge.
3. A two-node circular dependency is rejected. A mismatched domain sampling point, changed environment, invalid certificate and wrong query identity each cause revalidation to fail.
4. A spurious local trace remains inconclusive until concrete replay or refinement. A real subsystem counterexample preserves its cut assignments, schedule and source mapping.
5. Report elapsed time and peak memory for whole-model and composed checks using the same source, workload and approved host profile. Preserve both initial results even when decomposition has a larger combined cost.

[Finite-state composition oracle](proof_composition_oracle.py) · [Multi-clock scheduling review](multi-clock-scheduling-review.md)

## Glossary

| Term | Meaning |
| --- | --- |
| Boundary cut | Exposed signals whose values connect one partition to its environment or another partition. |
| DRAT | Deletion Resolution Asymmetric Tautology proof format for checked Boolean satisfiability queries. |
| Projection | Mapping from the concrete subsystem state and transitions to a local model. |
| SAT | Boolean Satisfiability. |


## Q3AFormal composition plan and source checks

A plan names existing single-clock, same-sample assertion properties. Every imported guarantee must be named by an earlier producer. The target is the last record. A cut removes the selected producer's original driver from that local model and exposes the same signal name, width and signedness as a free input.

```text
Q3AFORMAL_COMPOSITION 1
prove p_produce
prove p_consume p_produce
cut p_consume request
target p_top p_consume
```

The compiler regenerates each cone from the source design. It retains the original equations for the signals in the transitive fan-in, apart from the explicit cut drivers. Each retained equation is copied without rewriting its typed expression. Projection onto those signals preserves every retained equation. Supplying the original concrete values to the free cut inputs therefore embeds every legal concrete step into the local model. Guard state and initialization remain in the projection. The tool checks initial feasibility on the complete source model and records proof scope under the original source assumptions.

For a guarantee `G` with already checked predecessors `P`, the unrolled clauses encode these counterexample queries.

| Obligation | Query |
| --- | --- |
| Initial | Local initial constraints, environment at sample 0, predecessors at sample 0, and the negation of G at sample 0 |
| Transition | Local transition, environment and predecessors at samples 0 and 1, G at sample 0, and the negation of G at sample 1 |
| Target | Retained combinational equations, environment and imported guarantees at one arbitrary sample, and the negated target |

Every query must be unsatisfiable and have an independently checked Deletion Resolution Asymmetric Tautology (DRAT) artifact. The verification command reconstructs the queries from the RTL, manifest and plan and rejects different Conjunctive Normal Form (CNF) bytes or evidence. An inconclusive query or satisfying assignment for a local obligation reports `UNPROVEN` or `RESOURCE_LIMIT`. The complete marker is published only after every obligation has passed. A suspected subsystem violation can be checked through the concrete design's existing bounded model checking, witness bundle and source-required replay path.

```powershell
.\q3aformal-sourcecheck.exe prove-composition design.q3a --plan plan.q3c --output-dir certificate
.\q3aformal-sourcecheck.exe verify-composition design.q3a --plan plan.q3c --evidence-dir certificate
```

Both commands accept `--timeout-ms N`, `--memory-mib N` and `--cancel-file PATH`. Reopening requires the source and the exact plan bytes used to generate the certificate. This profile uses one-sample predicates and one-step inductive guarantees. Deferred work includes other proof engines and clock profiles, an independently supplied partition model, and subsystem benchmark qualification.

## Windows candidate qualification

The hierarchical producer–consumer design produced five checked obligations and agreed with the whole-source Property Directed Reachability (PDR) result. A guarded history property provided three further obligations, including an inductive transition that rejected a faulty next-state assignment. The standalone checker accepted all eight source-bound proof artifacts. A different wire polarity made the target obligation satisfiable, and the concrete model produced a source-replayed counterexample through the regular bounded model checking command. Removing the predecessor from the cut proof produced an unproven local obligation on a design whose whole-model property remained provable.

The same executable rejected cycles, changed plan or source bytes, swapped query or proof files, and a contradictory initial environment. Cancellation and a limited memory budget returned non-conclusive results. The prior parallel batch and strict proof or witness reopening regressions also passed. These results qualify the one-clock composition profile on the tested fixtures. [Composition test](test_proof_composition.ps1) · [Integration evidence](../../evidence/r-p2-composition-qualified/qualification.json) · [Standalone proof evidence](../../evidence/r-p2-composition-qualified/all-standalone-proofs.json)
