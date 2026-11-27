# Phase 0 Canonical Model Contract

**Status:** Phase 0 design contract, derived from owner-approved specification revision 0.10  
**Schema proposal:** T-IR schema 0.1

## 1. Purpose and proof boundary

The canonical transition-system intermediate representation (T-IR) is the single semantic input to property checking and witness replay. A result applies only to the exact T-IR, source profile, assumptions, and query identity recorded in the run bundle. The checker does not independently prove that source RTL was translated correctly; source-to-model evidence is separate.

## 2. Cycle convention

For frame t:

- S[t] is the RTL state immediately before active positive clock edge t.
- I[t] is the input/reset sample at edge t.
- Concurrent property expressions are evaluated from S[t] and I[t].
- The synchronous transition relation computes S[t+1].
- Nonblocking assignments update simultaneously.
- Reset participates in every transition and may remain asserted or reassert.

S[0] for RTL state is unconstrained unless an explicit supported initialization or recorded initial assumption constrains it.

## 3. Model entities

### Model

- schema_version
- semantic_profile_id and version
- top_module and stable elaborated hierarchy
- exact-width module-instance port map; reject any actual/formal bit-width mismatch before T-IR generation
- source files and content hashes
- parameter/define configuration
- model_hash over canonical serialized contents

### Signal

- stable signal_id and hierarchical name
- source span and source-to-model provenance
- packed width, signedness, and two-valued type
- role: state, input, output, internal combinational, or generated history state

### State vector

- ordered list of RTL state signals and generated history state
- initial-state constraint formula
- distinction between RTL state and tool-generated semantic state

### Input vector

- ordered top-level inputs, including the bound clock/reset metadata
- values are two-valued at each frame
- no implicit startup reset assumption

### Transition relation

A Boolean/bit-vector formula T(S[t], I[t], S[t+1]) containing:

- combinational equations evaluated from current state and inputs;
- next-state equations for every sequential variable;
- synchronous-reset branches in the same transition;
- explicit history-state updates;
- stable source provenance for each expression.

### Property

- property_id and source span
- kind: assert, assume, or cover
- bound clock and sampled expression/sequence
- resolved signal IDs and exact sequence operators
- property query hash and history guard delay, if any

### Assumption

- assumption_id and source span
- sampled predicate or initial-state constraint
- exact placement at initial state and/or each transition frame
- assumption hash and consistency-analysis status

## 4. Reset transition

For a register with synchronous reset value R:

- if reset is asserted at edge t, next value is R in S[t+1];
- otherwise, next value follows the non-reset sequential branch.

Registers without reset assignments have no reset override. Their initial values remain unconstrained unless separately constrained.

The transition relation must preserve simultaneous nonblocking update semantics. It must not replace reset with a one-time initial constraint.

## 5. Two-valued bit-vector semantics

- Every modeled data bit is 0 or 1.
- X/Z values in RTL data or literals are rejected, except Z/? wildcard positions in supported static casez patterns.
- Width, signedness, extension, truncation, and operator behavior follow the approved matrix and IEEE 1800 rules for each listed expression.
- Unsupported expression forms produce a diagnostic before proof-query construction.
- A procedural if evaluates its integral condition at the expression's own width. The branch is taken if any bit is set, including when only the high bit is set.

## 6. Case and casez

- case compares the two-valued selector to constant items with exact matching. The selector and all labels are evaluated at the largest operand width in the statement. Comparisons use signed evaluation only when every operand is signed.
- casez treats Z/? in static case-item patterns as wildcards.
- Sized unsigned binary, octal, and hexadecimal casez literals use one, three, and four bits per digit. A leading wildcard extends a short literal with wildcards. Other short literals extend with significant zero bits. Excess high bits are discarded at the declared literal width, which must match the selector width in this implementation.
- When multiple items match, the first matching source item is selected.
- X-valued selectors/patterns and unsupported qualifiers produce diagnostics.

## 7. SVA sampling and transition order

At sample t, assertions, assumptions, and covers read S[t] and I[t] before sequential updates. A supported finite sequence is represented by a symbolic automaton with explicit start and accepting states; each ordered transition carries a sampled predicate, delay from the preceding match end, and positive bounded consecutive-repetition interval. A bounded repeat may produce a match at each allowed end sample. For overlapped implication, each antecedent match launches the consequent at its end sample; for non-overlapped implication, the consequent starts at the following sample. A property failure points to the sample where the consequent is required and false. This sequence representation does not replace complete IEEE 1800 event/sampling semantics or the proof engine's property-monitor construction.

A property result records all assumptions and reset conditions used in that run.

A positive exact or ranged repetition of a compound sequence starts the next copy one sample after the preceding copy ends. Each copy preserves its internal delays. A range creates one accepting path for each legal expansion, with independent choices for nested ranges. An equal positive bound, such as `[*2:2]`, has the same meaning as an exact count. The serialized automaton records alternatives as disjoint paths with a shared start and accepting state. Lowering rejects expansions above 10,000 terms, and query construction rejects more than 4,096 expanded paths.

An explicit label before a module-level `assert property`, `assume property`, or `cover property` provides the check's name, including when the check references a separately declared property. Instance paths qualify labels in child modules. Unlabeled checks continue to use the referenced property name or the generated `property_check_N` name. Duplicate explicit labels and ambiguous check identities are rejected.

## 8. Generated history state for $past

For each required delay N, the model contains a shift register of prior sampled operand values and a generated history-valid condition.

- At S[0], history age and validity are zero/false. This generated state is fixed by the profile; it does not constrain RTL S[0].
- At each active edge, sampled operand values shift into history and the saturating age increases up to the largest required delay.
- At sample t, $past(expr,N) reads expr sampled at t-N.
- A property using $past is active only after enough samples exist for its largest requested delay. The warm-up suppression is an explicit profile restriction.
- Reset does not clear history state; only the initial model frame initializes it.
- The generated history state, delay, and guard are included in T-IR, model hashing, replay, and the result bundle.

## 9. Property query construction

- An assertion query searches for a reachable sample where the property is active and false under all recorded assumptions.
- An assumption constrains the legal environment at its declared temporal frames.
- A scalar or sequence cover query searches for a reachable sample/sequence match. A bounded implication-cover query is a nonvacuous reachability target: it requires an in-bound antecedent match and at least one complete in-bound consequent match. Vacuous property successes are not reported as `COVERED`; this API result is not a full implementation of IEEE cover-property coverage counters, which distinguish successful and vacuous-success counts ([IEEE 1800-2017 §16.14.3](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf)).
- A bounded miss yields BOUNDED_PASS for that finite bound or an incomplete cover result; it does not establish PROVEN or UNREACHABLE.
- A PROVEN result requires a complete checked induction or invariant argument for the recorded transition model.

## 10. Canonicalization and identity

Canonical serialization uses stable IDs and deterministic ordering for modules, signals, constraints, expressions, and properties. The model hash covers the serialized T-IR and generated history state. Query identity additionally covers the property, assumptions, reset policy, algorithm, bound, and options.

A bundle reopening verifies hashes before replay or checker validation. A mismatch is reported; source or model substitution is prohibited.

## Terminology

| Abbreviation | Meaning |
|---|---|
| IEEE | Institute of Electrical and Electronics Engineers |
| RTL | Register-transfer level |
| SVA | SystemVerilog Assertions |
| T-IR | Q3AFormal transition-system intermediate representation |


