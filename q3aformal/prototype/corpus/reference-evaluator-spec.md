# Independent Bounded Reference Evaluator — Specification

**Status:** Phase 0 corpus contract; implementation not yet started.

## Purpose and independence

Define a small reference evaluator for hand-reviewed bounded vectors. It is structurally separate from the planned RTL frontend, T-IR evaluator, SAT engine, and witness replay implementation. It consumes manually prepared state/input vectors and the expected mathematical transition equations. It does not parse general SystemVerilog and is not a proof oracle.

Expected results must be derived from the specification and vector equations, then reviewed before comparison to the implementation.

## Value representation

- Each signal is an unsigned or signed packed bit-vector with an explicit width.
- Every bit is 0 or 1. Any X/Z source value is rejected.
- Module connections require exact actual/formal bit-width matches in profile Q3A-P0-R0.9.1; mismatches are rejected before reference evaluation and no implicit extension/truncation is applied.
- Addition and subtraction wrap to the explicitly resolved result width.
- Comparisons follow the resolved signedness and operand widths.
- Concatenation preserves source ordering; constant selects use the declared range mapping.
- case uses exact equality. casez treats Z/? bits in case-item patterns as wildcards; items are checked in source order.

## Cycle and reset convention

- Frame t contains state S[t] immediately before the active positive clock edge and sampled inputs I[t].
- Concurrent properties sample S[t] and I[t].
- Transition evaluation computes S[t+1].
- Synchronous reset is checked at every transition. It updates registers with reset assignments on that edge.
- S[0] is unconstrained unless the vector explicitly supplies an initial constraint.
- No startup reset is assumed implicitly.

## Transition evaluation

For each step:
1. Read state and input values for frame t.
2. Evaluate concurrent property operands and property matches at sample t.
3. Evaluate each sequential process from the pre-edge state and input sample.
4. Apply nonblocking assignments simultaneously to obtain S[t+1].
5. Check the expected state against the vector equation.

The reference evaluator reports the first frame and signal where the expected and observed values differ.

## Assertion semantics in the corpus

- |-> starts the consequent at the same sample at which the antecedent sequence ends.
- |=> starts the consequent at the next sampled clock edge.
- ##N uses a constant nonnegative number of sampled cycles; ##0 has no cycle separation.
- [*N] requires positive constant N; [*m:n] requires positive constant bounds 1 <= m <= n. Exact zero-count and zero-minimum repetitions are rejected.
- $past(expr) means the prior sample. $past(expr,N) means the value sampled N edges earlier.
- A model-generated history-valid bit starts false and becomes true after the required number of active clock samples. A property containing $past is suppressed until its maximum requested delay is valid. History is not cleared by reset.
- Unsupported syntax has no evaluator meaning and must be rejected before query generation.

## Metamorphic relations

These transformations may be used only when the transformation's preconditions hold:

1. Reordering independent continuous assignments preserves values and transitions.
2. Renaming a local signal consistently preserves model behavior and property outcomes.
3. Replacing a constant expression with an equivalent constant expression preserves behavior after width/signedness are resolved.
4. Splitting a packed vector into equal slices and re-concatenating in the same order preserves the bit-vector value.
5. Reordering non-overlapping case/casez items preserves output values. Overlapping casez items must not be reordered because first-match priority is observable.
6. Changing an unreachable generate branch must not change the elaborated model for the fixed parameter configuration.

Each applied relation records the source pair, precondition, expected invariant, and result.

## Limitations

The reference evaluator checks only the authored bounded corpus. It does not establish full IEEE conformance, unbounded reachability, SAT solver correctness, or source-to-model soundness for arbitrary designs.

## Terminology

| Abbreviation | Meaning |
|---|---|
| IEEE | Institute of Electrical and Electronics Engineers |
| RTL | Register-transfer level |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |


