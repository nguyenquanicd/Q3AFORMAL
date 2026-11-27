# Research: Q3AFormal Phase 0 Feasibility

**Feature:** 002-phase0-feasibility  
**Purpose:** Compare implementation approaches and record what must be decided before prototype work.

## Findings

### 1. Use a narrow end-to-end slice

A full frontend, SystemVerilog Assertions (SVA) compiler, Boolean satisfiability (SAT) solver, model checker, proof checker, result format, and graphical debugger is too broad for the first feasibility question. The shortest useful experiment is a restricted one-clock synchronous transition model that can produce one checked proof and one independently replayed counterexample.

This slice tests the trust chain from source parsing to model semantics, proof-query generation, evidence checking, and result reopening. It does not establish full-language conformance, scalability, or product readiness.

### 2. Keep source-to-model evidence separate from proof-artifact evidence

A proof checker can validate evidence against a supplied transition model; it does not establish that the model faithfully represents the source design. Phase 0 therefore needs two different evidence paths:

1. Proof-artifact checker evidence for Boolean unsatisfiability or an inductive invariant.
2. Source-to-model evidence with reviewed expected elaborated/transition behavior and a separately structured bounded evaluator.

Metamorphic transformations can strengthen the second path, but they do not replace expected vectors or semantic review. External formal engines are excluded as correctness oracles by the product specification.

### 3. Restrict uncertain language features explicitly

The existing review identifies unresolved semantics around synchronous reset, unbased versus numeric literals, SystemVerilog Assertions disable timing, and first-sample history. The owner-approved balanced profile includes only constructs whose exact parse, elaboration, transition, and property behavior is represented in the versioned conformance matrix. Unsupported constructs must fail before proof.

The approved Phase 0 subset excludes asynchronous reset, disable iff, sampled-value history functions other than guarded $past, multi-clock properties, liveness/fairness, and any syntax without complete vectors. Case/casez, bounded consecutive repetition, and guarded $past are included. This is the Phase 0 owner decision; later profile expansion remains open.

### 4. Treat proof format as a Phase 0 experiment

The existing specification lists Delete Resolution Asymmetric Tautology (DRAT) as a candidate but does not freeze it. Evaluate candidate proof formats against:
- checker size and implementation complexity;
- independent checker structure;
- support for the chosen solver's output;
- malformed and single-defect artifact rejection;
- bundle portability and versioning;
- runtime and peak-memory cost.

Do not choose a format from reputation alone. The owner approves the candidate for evaluation at Gate A and the final format based on Gate B evidence.

### 5. Store the exact model in every result bundle

A source snapshot alone cannot guarantee that a future parser/lowering build regenerates identical semantics. Each bundle should carry the exact canonical transition model, model schema, provenance, model hash, property/query identity, assumptions, proof or witness, and the tool/checker identity. A compatible checker may revalidate evidence; without one, the application must clearly label the status as historic.

### 6. Keep performance claims tied to a frozen benchmark protocol

Runtime and memory are meaningful only for an identified hardware profile and fixed benchmark/configuration. Select workloads, expected outcomes, limits, and thresholds before measurement. Report every timeout, resource limit, and unsupported case. A small Phase 0 benchmark supports feasibility decisions only for those workloads.

## Alternatives

| Alternative | Benefits | Costs and risks | Decision |
|---|---|---|---|
| Implement full MVP before validating a single property | Broad architecture is visible early | Large sunk cost and coupled semantic defects | Not recommended |
| Wrap an existing open-source frontend/solver/formal engine | Fast capability demonstration | Violates the no-third-party runtime boundary and obscures Q3A evidence contracts | Rejected for the product |
| Implement a small Q3A-owned vertical slice | Tests the critical path and evidence model with limited semantics | Narrow results; independent corpus and checker still need careful review | Approved by owner at Gate A |
| Write a specification only and defer all prototype work indefinitely | Low initial engineering cost | Leaves feasibility questions unanswered | Not selected; Gate A has been approved and Phase 0 work is authorized |

## Owner Decisions and Remaining Evidence Gates

| Decision | Proposed path | Status |
|---|---|---|
| Language and build standard | C++17 selected for Phase 0; review retention at Gate B | Selected for Phase 0 |
| Target platform/hardware | Windows x64 development host; record exact host configuration before measurement | Selected; measurement record pending |
| Phase 0 RTL/SVA subset | Balanced profile approved by owner; reject unlisted constructs | Approved |
| Reset and initial state | Synchronous reset every transition; unconstrained S0 absent declared constraints | Approved |
| Proof artifact/checker | Evaluate DRAT first with malformed/defective corpus; final format at Gate B | Evaluation plan approved |
| Benchmark and thresholds | Independently authored microdesigns; freeze numeric limits before measurements | Method approved; numeric limits pending |
| Product dependency boundary | Preserve Q3A-owned runtime and no external proof oracle | Approved approach |

## Sources

- [IEEE 1800-2023 SystemVerilog standard landing page](https://standards.ieee.org/ieee/1800/7743/)
- [Heule, Hunt, Wetzler: DRAT-trim and checking DRAT proofs](https://arxiv.org/abs/1610.06229)
- The revision 0.8 snapshot under inputs/ and the earlier review report in the sibling 001-q3aformal-spec-analysis feature.

## Terminology

| Abbreviation | Meaning |
|---|---|
| ASIC | Application-specific integrated circuit |
| DRAT | Delete Resolution Asymmetric Tautology proof format |
| IR | Intermediate representation |
| SAT | Boolean satisfiability |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |




