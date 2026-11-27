# Four-state expression qualification

This Phase 3 component evaluates already sized SystemVerilog packed integral expressions over `0`, `1`, unknown (`X`), and high impedance (`Z`). The concrete evaluator stores two 64-bit planes. The symbolic encoder represents each bit by two Boolean Satisfiability (SAT) literals. Both representations distinguish all four symbols. The width limit is 1–64 bits. The caller resolves SystemVerilog context sizing and signedness before evaluation.

| Operation | Concrete evaluation | SAT encoding |
| --- | --- | --- |
| Bitwise conjunction, disjunction, and exclusive OR | Supported | Supported |
| Bitwise complement and logical conjunction, disjunction and negation | Supported | Supported |
| Logical and exact case equality | Supported | Supported |
| Right-hand wildcard equality and inequality in the development source build | Supported | Supported |
| Packed addition, subtraction, unary negation, and relational comparison | Supported | Supported |
| Packed integral multiplication in the development source build | Supported | Supported |
| Packed integral division and remainder in the development source build | Supported | Supported |
| Logical and arithmetic shifts with constant or variable distances | Supported | Supported |
| Integral conditional expression | Supported | Supported |
| Reduction AND, OR, XOR, NAND, NOR, and both XNOR spellings | Supported | Supported |
| Plain `case` and `casez` item comparison | Supported | Supported |
| Procedural `casex` in the development source build | Supported | Supported |
| Signed or unsigned resize, constant slicing, and concatenation | Supported | Supported |
| Packed single-bit reads with variable indices | Supported | Supported |
| Packed indexed part-select reads with constant widths | Supported | Supported |

Packed multiplication uses the expression context width, including signed extension when both operands are signed under that context. It keeps the low product bits at that width. Any `X` or `Z` operand bit makes the entire product `X`, including multiplication by zero. The concrete evaluator uses an unsigned machine product and width masking. The symbolic encoder independently builds the partial-product additions for the selected width. [IEEE Std 1800-2017, §§11.4.3, 11.6, and 11.8](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Multiplication regression](test_four_state_multiply.ps1) · [Windows evidence](../../evidence/p3-four-multiply/qa-multiply/qualification.json)

Wildcard operators `==?` and `!=?` ignore positions with `X` or `Z` in the right operand. The literal digit `?` specifies a `Z` wildcard in a packed pattern. A known mismatch on a required bit resolves the comparison. When no known mismatch exists, an unknown left bit at a required position yields `X`. Operand extension follows the same signedness and width rules as logical equality. [IEEE Std 1800-2017, §11.4.6](https://rfsoc.mit.edu/6S965/_static/F25/documentation/1800-2017.pdf) · [Wildcard regression](test_four_state_wildcard_equality.ps1) · [Windows evidence](../../evidence/p3-four-wildcard/qa-wildcard_equality/qualification.json)

Source builds after revision 10 support packed integral division and remainder at the expression context width. Signed division truncates toward zero. A nonzero remainder has the dividend's sign. Division or remainder with a zero divisor or an operand containing X or Z yields an all-X result. Constant delay bounds must resolve to a valid integer, and a zero divisor in such a bound is rejected. The concrete evaluator uses unsigned magnitudes. The symbolic encoder uses a restoring divider before applying result sign and unknown handling. [IEEE Std 1800-2017, §11.4.3](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf) · [Division and remainder regression](test_four_state_divide.ps1) · [Windows evidence](../../evidence/p3-four-division/qa-divide/qualification.json)

In logical equality, a known unequal bit forces a false result. Unknown bits yield an unknown result when the remaining bits cannot resolve equality. Exact equality compares the symbols themselves and always returns a binary result. In a conditional expression with an ambiguous selector, a result bit is preserved only when both branches have the same known value at that bit. Two `Z` bits yield `X` in the ambiguous merge. A known selector preserves the selected branch, including `Z`. [IEEE Std 1800-2017, sections 11.4.5, 11.4.7–11.4.11 and 12.5](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

Procedural `casex` ignores an `X` or `Z` bit in either the packed selector or the packed item expression. The first matching source item wins. Items can use literals or supported signal expressions, with a common comparison width and signedness. This profile requires an explicit `default:` in `always_comb`. In `always_ff`, when no item matches and no default is present, the assigned register holds its previous value. [IEEE Std 1800-2017, §12.5.1](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Case comparison regression](test_four_state_casex.ps1) · [Windows evidence](../../evidence/p3-four-casex/qa-casex/qualification.json)

The reduction operators produce one unsigned logic bit. A known zero determines AND and NAND. A known one determines OR and NOR. A reduction XOR or XNOR returns `X` when any input bit is `X` or `Z`. The development profile accepts these operators in RTL assignments and sampled SystemVerilog Assertions. [Reduction regression](test_four_state_reductions.ps1) · [Windows evidence](../../evidence/p3-four-shift/reductions-final/qualification.json)

Packed addition, subtraction, and unary negation use the resolved expression width. Known operands wrap at that width. An `X` or `Z` operand bit makes every arithmetic result bit `X`. Relational comparisons return one `X` bit for an unknown operand. Known operands use signed comparison when both operands are signed and unsigned comparison otherwise. [IEEE Std 1800-2017, sections 11.4.3 and 11.4.4](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Arithmetic source regression](test_four_state_arithmetic.ps1) · [Windows evidence](../../evidence/p3-four-arithmetic/qualification.json)

Shifts move both logic planes, preserving shifted `X` and `Z` bits. Logical shifts and arithmetic left shifts fill with zero. Arithmetic right shifts fill with the sign bit of a signed result, including when that bit is `X` or `Z`. The distance is unsigned and self-determined. An unknown distance makes the whole result `X`, and a known distance at or above the result width moves all original bits out. [IEEE Std 1800-2017, section 11.4.10](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Shift source regression](test_four_state_shifts.ps1) · [Windows evidence](../../evidence/p3-four-shift/qualification.json)

For supported `case` and `casez` statements, the first matching arm wins. Plain `case` compares each four-state symbol exactly. In `casez`, any `Z` bit in either operand permits that bit to match, and a literal `?` is equivalent to `Z`. The supported `casez` labels are sized unsigned binary, octal, or hexadecimal patterns with the selector width. A sequential `case` without a matching arm or default retains the previous register value. [IEEE Std 1800-2017, sections 12.5 and 12.5.1](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Case regression](test_four_state_case.ps1) · [Windows evidence](../../evidence/p3-four-case/qualification.json)

A single-bit read such as `data[index]` evaluates the index in its own width and signedness. The declared packed range determines which bit number corresponds to each physical position. An unknown or out-of-range index yields `X`. A valid index preserves the selected symbol, including `Z`. This path accepts reads in supported RTL expressions, child input connections, and finite SystemVerilog Assertions. [IEEE Std 1800-2017, section 11.5.1](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Indexed-read regression](test_four_state_indexed_bits.ps1) · [Windows evidence](../../evidence/p3-four-select/qualification.json)

Indexed part-select reads use `data[base +: width]` or `data[base -: width]`, with an independent base expression and a constant result width from 1 to 64. The declared range and operator determine result bit order. Bits outside the declared range read as `X`, while in-range bits preserve their four-state values. An unknown base yields an all-`X` result. The SAT encoder shares each decoded base condition across all result bits that use it. [IEEE Std 1800-2017, section 11.5.1](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Indexed part-select regression](test_four_state_indexed_parts.ps1) · [Windows evidence](../../evidence/p3-four-part/qualification.json)

## Independent checks

The word test uses per-symbol tables and compares every pair of four-bit operands. It checks 65,536 operand pairs, 262,144 conditional evaluations, and 14 width, normalization, and invalid-input checks. The SAT test independently constrains every assignment of three two-bit words. It requires a satisfying assignment for the inputs, then adds a clause demanding at least one disagreement on the six encoded results. All 4,096 input triples were satisfiable before the disagreement clause and unsatisfiable after it. These are component checks. [Concrete test](test_four_state_word.cpp) · [SAT test](test_four_state_sat.cpp) · [Windows evidence](../../evidence/p3-four-state/qualification.json)

## Evaluate source RTL

Build a separate Windows executable with `-EnableDevelopmentFourState`. Set `option profile Q3A-FOUR-STATE-DEVELOPMENT` in the version 2 project manifest. Reachable modules may contain packed `logic` ports and internal signals with continuous assignments and `always_comb` blocks. Combinational targets must be assigned on every path, and `always_comb` case statements require a default arm. Each input takes a fixed-width, most-significant-bit-first string containing `0`, `1`, `x`, or `z`. Supply every input exactly once.

```powershell
.\prototype\source\source_manager\build.ps1 -EnableDevelopmentFourState `
    -Output evidence\four-state-local\q3aformal-sourcecheck.exe
$exe = '.\evidence\four-state-local\q3aformal-sourcecheck.exe'
& $exe dev-eval-four-state project.q3a --input sel x --input a 0z --input b x1
```

The evaluator derives widths and signal dependencies from the parsed design. It accepts binary, octal, and hexadecimal literals containing unknown bits, plus the `'x` and `'z` fill literals. The result contains the evaluated input, internal, and output values and both manifest and model digests. Use the exact output width when interpreting bit strings. An undriven signal, unsupported operator, or unsupported module feature fails explicitly. [SystemVerilog literal sizing, IEEE Std 1800-2017, section 5.7.1](https://rfsoc.mit.edu/6S965/_static/F25/documentation/1800-2017.pdf) · [Source regression](test_four_state_source.ps1) · [Windows evidence](../../evidence/p3-four-rtl/qa/qualification.json)

## Prove an exact output value

The development proof command checks whether an output equals a supplied bit string for every combination of four-state inputs. It derives the symbolic equations from the same elaborated combinational RTL accepted by the evaluator. Each input bit ranges over `0`, `1`, `X`, and `Z`. Comparison is exact on both bit planes.

```powershell
& $exe dev-prove-four-state project.q3a --expect masked 0000 --evidence-dir proof-masked
& $exe dev-verify-four-state project.q3a --expect masked 0000 --evidence-dir proof-masked
```

`PROVEN` includes the regenerated-query digest and the checked Deletion Resolution Asymmetric Tautology (DRAT) certificate digest. The evidence directory contains `query.cnf` and `proof.q3adrat`. Independent verification binds the source model, manifest, build, output name and expected bit string. The verifier regenerates the query from source and checks the certificate without proof search. For standalone checking, pass the JSON field `proof_model_sha256` to `q3aformal-proofcheck --check-drat proof-masked/query.cnf proof-masked/proof.q3adrat --model-sha256 DIGEST --query-kind four-state-exact`.

`COUNTEREXAMPLE` returns the decoded input and signal values after the independent concrete evaluator confirms the difference. The command publishes a proof directory only after a certificate checks. A resource or control stop returns an incomplete result. Use `--timeout-ms N`, `--memory-mib N`, or `--cancel-file PATH` to control a run. [Proof regression](test_four_state_proof.ps1) · [Windows evidence](../../evidence/p3-four-proof/qa/qualification.json)

## Check a sampled sequential design

Use `--steps N` to check an output or modeled register at exactly sample `N`, after `N` updates. The development profile admits module hierarchies with one positive-edge clock, continuous assignments, and `always_ff` blocks with nonblocking assignments and procedural `if/else`, `case`, and `casez`. Sample zero is the initial pre-update state. Uninitialized logic registers start at `X`. Each update evaluates all right-hand sides using the same pre-update values and commits their results together. The model receives an abstract positive-edge event at each update, and the sampling clock may not also be used as data. The other input bits may take any of the four states independently at every sample. [SystemVerilog initialization and nonblocking assignments, IEEE Std 1800-2017, Table 6-7 and section 10.4.2](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

```powershell
& $exe dev-prove-four-state project.q3a --expect q x --evidence-dir initial-q --steps 0
& $exe dev-verify-four-state project.q3a --expect q x --evidence-dir initial-q --steps 0
```

A procedural `if` takes its first branch only when its condition is true. An ambiguous condition in a conditional expression `?:` uses the four-state bit merge. Consequently, an unknown selector can produce a known result for procedural `if` and an unknown result for the corresponding expression. [SystemVerilog conditional behavior, IEEE Std 1800-2017, sections 11.4.11 and 12.4](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

A checked sampled claim reports `BOUNDED_PASS` with exit code 0 for the requested sample and publishes a certificate of kind `four-state-sampled-exact`. The maximum index is 128. Reopening requires the same step count, which is part of the proof identity. Counterexample JSON includes all samples through the failure at the requested step. Replay starts at the defined initial state and recalculates each register update. [Sequential proof regression](test_four_state_sequential.ps1) · [Windows evidence](../../evidence/p3-four-seq/qa/qualification.json)

## Check a named sampled assertion

The sampled model checks a direct finite sequence or a finite implication written with `|->` or `|=>`. It accepts inline assertion labels and labels that reference a named property in the top module. Supported operands use scalar predicates, fixed or finite ranged delays, and positive consecutive repetition. The maximum sequence offset is 128. Use `--property NAME` and `--steps N`.

Development source builds after revision 7 also accept finite sequence `or`. Both operands start at the same sample and either can supply a match. In an implication antecedent, distinct matches from both operands create obligations at their respective endpoints. The delay operator `##` binds more tightly than `or`. Parenthesize an alternative before concatenating it as a unit or applying consecutive repetition to it. [IEEE Std 1800-2017, §16.9.7](https://rfsoc.mit.edu/6S965/_static/F25/documentation/1800-2017.pdf) · [Sequence disjunction regression](test_four_state_sequence_or.ps1) · [Windows evidence](../../evidence/p3-four-sva-or/qa/qualification.json)

Development source builds with finite sequence `intersect` pair matches from the same start and endpoint. A paired path requires every predicate of both operands at its original sample. When an antecedent has several shared endpoints, each endpoint contributes its own implication obligation. The parser follows the precedence of `##`, `intersect`, and `or` from tightest to loosest. Each operand must fit within 128 sample offsets, and each operand expansion and the combined sequence must fit within 10,000 sampled term entries. When there are no structurally shared endpoints, the model represents an impossible match at the longer operand's horizon. [IEEE Std 1800-2017, §16.9.6 and Table 16-3](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf) · [Sequence intersection regression](test_four_state_sequence_intersect.ps1) · [Windows evidence](../../evidence/p3-four-intersect/qa/qualification.json)

Finite sequence `and` pairs matches from the same start. Each pair requires both operands and ends when the later operand finishes. A shorter operand remains matched while the other finishes. The same sample and expansion limits apply. The precedence from tightest to loosest is `##`, `intersect`, `and`, then `or`. [IEEE Std 1800-2017, §16.9.5 and Table 16-3](https://rfsoc.mit.edu/6S965/_static/F25/documentation/1800-2017.pdf) · [Sequence conjunction regression](test_four_state_sequence_and.ps1) · [Windows evidence](../../evidence/p3-four-and/qa-sequence_and/qualification.json)

In source builds with `throughout`, a one-bit condition must be true at every sample from the start of each finite match to its endpoint, including samples skipped by a concatenation delay. Each alternative uses its own interval. The operator is right-associative and binds more tightly than `intersect` and less tightly than `##`. The body and the lowered sequence follow the same offset and term limits as finite conjunction. For example, `grant throughout (req ##2 ack)` checks `grant` at the request, at the intermediate sample, and at the acknowledgment. [IEEE Std 1800-2017, §16.9.9 and Table 16-3](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf) · [Throughout regression](test_four_state_sequence_throughout.ps1) · [Windows evidence](../../evidence/p3-four-throughout/qa/qualification.json)

In source builds with `within`, the inner sequence may match anywhere inside the enclosing sequence, including either boundary. The composite match retains the enclosing sequence's start and endpoint. An implication whose antecedent has multiple enclosing endpoints checks all those endpoints. The precedence from tightest to loosest is `##`, `throughout`, `within`, `intersect`, `and`, then `or`. The 128-sample offset and 10,000-term limits apply to the operands and the lowered timing alternatives. [IEEE Std 1800-2017, §16.9.10 and Table 16-3](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf) · [Within regression](test_four_state_sequence_within.ps1) · [Windows evidence](../../evidence/p3-four-within/qa-sequence_within/qualification.json)

Development source builds with window pruning discard repetition choices that cannot finish inside the requested sample window. The maximum declared sequence offset still controls which assertion and assumption obligations can be decided. The four-state checker caps viable expansion at 1,000,000 sampled term entries per sequence and checks the available memory budget before storing batches of entries. If the budget is exceeded, the command reports `RESOURCE_LIMIT` and publishes no proof or witness. Qualification compares the regenerated query and the sampled trace across builds. Archived proof and witness metadata continue to bind to their originating build. [Window pruning regression](test_four_state_window_pruning.ps1) · [Windows evidence](../../evidence/p3-four-window/qualification.json)

Development source builds after revision 11 support `first_match(sequence)` on finite sequences in the four-state profile. For each attempt, it keeps every matching alternative at the earliest endpoint on that trace. An earlier predicate that evaluates to X or Z cannot match. For example, `first_match(req ##[1:3] ack) ##1 done` checks `done` after the first matching acknowledgment even when a later acknowledgment would satisfy the concatenation. The same finite offset and term limits apply, with an additional limit of 200,000 copied nodes for sampled guards. Sequence match items, such as local assignments, are excluded. [IEEE Std 1800-2017, §16.9.8](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf) · [First-match regression](test_four_state_first_match.ps1) · [Windows source-build evidence](../../evidence/p3-four-first-match/qa-first_match/qualification.json)

Each antecedent match is checked separately. The consequent starts at its match endpoint for `|->` and one sample later for `|=>`. An attempt can report a failure only when the entire consequent window fits within the bound. A standalone sequence requires its own full window. A query with no possible completed attempt slot is rejected. The finite check leaves attempts extending beyond the bound open.

```systemverilog
p_next_request: assert property (@(posedge clk) req |=> accepted);
```

```powershell
& $exe dev-prove-four-state project.q3a --property p_next_request --evidence-dir proof --steps 8
& $exe dev-verify-four-state project.q3a --property p_next_request --evidence-dir proof --steps 8
```

Only a true antecedent matches. A standalone Boolean assertion or the consequent of a matched implication succeeds only when true. A consequent that evaluates to `0`, `X`, or `Z` fails. A property evaluated at a sample can therefore report a failure from unknown data even when an implication using that data as its antecedent has no match. [SystemVerilog Assertions, IEEE Std 1800-2017, sections 16.6 and 16.12.7](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

A bounded certificate uses query kind `four-state-sampled-sva`. It can be checked by the standalone proof checker or regenerated from the original RTL using the same property and bound. A replayed counterexample gives `attempt_sample` and `failure_sample` for its earliest completed failure. Implications also include `antecedent_end_sample`. The `signals` object describes the failure sample, while `trace` retains the complete sampled window. A bounded pass establishes absence of a completed failure in that window and can be vacuous if there is no antecedent match. The checker expands finite timing alternatives into sampled SAT predicates. The replay evaluator separately walks the original sequence automaton using the four-valued trace. [Assertion regression](test_four_state_sva.ps1) · [Sequence regression](test_four_state_sequences.ps1) · [Windows evidence](../../evidence/p3-four-sequence/qualification.json)

## Select a property in a child instance

Development source builds after revision 12 support reusable, module-local named properties without formal arguments. Reference the whole property by its name or with empty parentheses. A property can refer to another named property in the same module, including a declaration that appears later. Use a single explicit positive-edge sampling clock at the check or in the referenced declarations. Multiple explicit clocks in the chain must name the same signal. The check retains its assertion, assumption, or coverage kind and its own source location. Predicate locations come from the original declarations.

```systemverilog
property ready_next;
    request |=> ready;
endproperty

p_ready: assert property (@(posedge clk) ready_next());
```

The finite profile resolves whole-property aliases and supports up to 128 declaration references in a chain. It rejects recursive references, unresolved names, formal and actual arguments, conflicting clocks, and checks with no bound sampling clock. [IEEE Std 1800-2017, §16.12](https://rfsoc.mit.edu/6S965/_static/F24/documentation/1800-2017.pdf) · [Named property regression](test_four_state_named_property.ps1) · [Verified source-build evidence](../../evidence/p3-named-property/final-named_property/qualification.json)

Development source builds after revision 10 accept module-local, parameterless `sequence` declarations. Use a bare name or an empty argument list as a finite sequence term. References may precede the declaration, use other named sequences, and appear inside bounded repetition and supported temporal compositions. Expansion uses the declaring module's signals and preserves the source locations of its predicates. Each elaborated instance resolves the same declarations against its own connections. This profile rejects formal arguments and referenced recursion. [IEEE Std 1800-2017, §16.9.11](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf) · [Named sequence regression](test_four_state_named_sequence.ps1) · [Windows evidence](../../evidence/p3-four-named-sequence/qa-named_sequence/qualification.json)

The hierarchy is elaborated with exact port widths. Child input variables use the declared formal signedness, and each instance keeps its own register and sampled-history state. A child clock must connect directly through the hierarchy to the single one-bit top input. Select a child assertion or cover by its instance path, such as `--property box.left.p_history`. Saved evidence and waveforms use the elaborated names. [Hierarchy regression](test_four_state_hierarchy.ps1) · [Windows evidence](../../evidence/p3-four-hierarchy/final/qualification.json)

## Find a completed cover match

Select a named `cover property` with `--property` and set `--steps N` to search samples 0 through N. Cover accepts the same supported scalar predicates, finite delays, positive consecutive repetitions, sampled history and implication alignments as assertions. An implication cover needs a matching antecedent and a matching consequent. Only completed matches contribute to the result, including shorter alternatives that finish within the bound.

```powershell
& $exe dev-prove-four-state project.q3a --property c_request --evidence-dir cover-evidence --steps 8
```

`COVERED` (exit 0) includes a replay-validated trace in JSON. `attempt_sample` and `match_sample` describe the earliest ending match within that trace. For an implication, `antecedent_end_sample` gives the antecedent endpoint. A match under assumptions that extend beyond the bound reports `WITNESS_PENDING_ASSUMPTION` (exit 1). A found trace is emitted to standard output and saved as `cover.q3awitness` in the evidence directory. The artifact binds the design, manifest, build, property, and sample bound to the regenerated query. It stores the sampled input values. The checker reconstructs register and wire values from the source and verifies the full trace against the completed assumptions.

Run `dev-verify-four-state` with the same arguments to reopen a saved trace. The checker replays the source without running a SAT search and reports `witness_revalidated: true` with the artifact SHA-256 digest. A provisional witness remains provisional. An alternate input trace can yield another valid witness with its own digest.

`NOT_FOUND_WITHIN_BOUND` (exit 1) publishes a Deletion Resolution Asymmetric Tautology (DRAT) certificate that proves the absence of a complete match within the supplied bound. Use `dev-verify-four-state` with the same arguments to recover `REVALIDATED`, or verify the saved CNF and DRAT separately with query kind `four-state-sampled-cover`. [Cover qualification script](test_four_state_cover.ps1) · [Windows evidence](../../evidence/p3-four-cover-replay/qualification.json)

## Save and reopen a counterexample

Pass `--save-witness` to `dev-prove-four-state` to publish a validated counterexample as `counterexample.q3awitness` in the selected evidence directory. The counterexample stores ordered input samples and binds the source model, claim, bounds, and query. Reopen it with `dev-verify-four-state` and the original project and claim arguments. The verifier reconstructs the trace from RTL, checks completed assumptions, and confirms the output mismatch or earliest completed assertion failure without SAT search.

```powershell
& $exe dev-prove-four-state project.q3a --property p_assert --evidence-dir assertion-failure --steps 8 --save-witness
& $exe dev-verify-four-state project.q3a --property p_assert --evidence-dir assertion-failure --steps 8 --vcd assertion-failure.vcd
```

A reopened result includes `witness_revalidated: true`, the artifact digest, and the original outcome class, including provisional status when assumptions extend beyond the bound. A successful proof still publishes its normal certificate. [Counterexample regression](test_four_state_counterexample_artifacts.ps1) · [Windows evidence](../../evidence/p3-four-counterexample/qualification.json)

## Inspect a replayed waveform

Pass `--vcd FILE` to `dev-prove-four-state` or `dev-verify-four-state` to export a replayed cover match or counterexample as Value Change Dump (VCD). The selected file path must be unused and its parent directory must already exist. The waveform records each sample on a 1 ns index timebase, preserves packed ranges and the `0`, `1`, `X`, and `Z` values, and shows the abstract positive-edge sampling event. Diagnostic markers show the attempt, antecedent endpoint, and match or failure when available.

```powershell
& $exe dev-verify-four-state project.q3a --property c_request --evidence-dir cover-evidence --steps 8 --vcd cover.vcd
& $exe trace view-vcd cover.vcd | Set-Content -Encoding utf8 cover.html
```

A run without a replayed trace produces no waveform. The VCD and the generated self-contained HTML viewer are for inspection. Use the original saved witness and RTL to revalidate the formal result. [Waveform qualification script](test_four_state_vcd.ps1) · [Windows evidence](../../evidence/p3-four-vcd/qualification.json)

## Constrain the sampled environment

The four-state profile accepts finite `assume property` declarations on the same sampled clock as the assertion. The assumption syntax uses the same scalar predicates, delays, repetitions, and implication alignment as assertions. All completed assumption obligations constrain the SAT query. An unknown scalar assumption fails when it must hold, while an unknown implication antecedent does not start its consequent. [SystemVerilog Assertions, IEEE Std 1800-2017, section 16.12.7](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

Before checking a property or reopening its certificate, the tool checks satisfiability of the completed assumptions independently of the assertion. It replays a feasible environment from source. A contradiction returns `INCONSISTENT` with exit code 1 and no assertion proof directory. A changing assumption can change the regenerated query and proof identity.

A witness is replayed against the RTL and all completed assumption obligations. With only same-sample assumptions it can return `COUNTEREXAMPLE`. If the project has a temporal assumption, the checker conservatively reports `WITNESS_PENDING_ASSUMPTION` with exit code 1 and `assumption_boundary_open: true`. The window establishes the completed assumption obligations, while future samples may still constrain extension of the witness. [Assumption regression](test_four_state_assumptions.ps1) · [Windows evidence](../../evidence/p3-four-assume/qa/qualification.json)

## Use sampled history

The four-state assertion and assumption profile accepts `$past(signal)`, `$past(signal, N)`, `$stable`, `$changed`, `$rose`, and `$fell`. The sampled argument is a declared packed `logic` signal or a constant select of one. The delay is an elaboration-time integer from 1 to 128. All operations use the property's positive-edge sampling clock.

Before a requested prior sample exists, history returns the default sampled value of the supported uninitialized logic operand, `X` in every bit. The checker still evaluates the assertion or assumption at these early samples. Once history is available, both value planes are preserved. Stability compares every bit, including `X` and `Z`. Rising and falling tests use the least significant bit and detect a change to `1` or `0`, including a change from `X` or `Z`. [IEEE Std 1800-2017, sections 16.5.1 and 16.9.3](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

```systemverilog
p_pipeline: assert property (@(posedge clk) q === $past(d));
p_z_held: assert property (@(posedge clk)
    ((d === 1'bz) && ($past(d) === 1'bz)) |-> $stable(d));
```

The compiler shares matching history stages and updates every stage from the prior sampled state. The concrete replay reconstructs those stages while checking a witness. Gated or alternate-clock samples and compound sampled arguments are excluded. [History regression](test_four_state_history.ps1) · [Windows evidence](../../evidence/p3-four-history/qa/qualification.json)

## Inspect the four-state model

Development source builds after revision 9 accept `dev-lower-four-state PROJECT` and write the versioned Transition Intermediate Representation (T-IR) to standard output. The model includes typed equations, elaborated names, temporal transitions and source locations. The command uses the same source loader as four-state evaluation and proof, but performs no proof search. The `model_sha256` reported by evaluation or proof hashes the canonical JSON without the final console newline. [Model export regression](test_four_state_model_export.ps1) · [Windows evidence](../../evidence/p3-four-model-export/qa-model_export/qualification.json)

```powershell
& $exe dev-lower-four-state project.q3a | Set-Content -Encoding utf8NoBOM -NoNewline model.json
Get-FileHash model.json -Algorithm SHA256
```

## Remaining proof integration

The sampled profile supports finite cover and source-backed replay of saved cover and counterexample witnesses as described above. Unbounded four-state properties, physical clock transitions involving unknown states, asynchronous events, driver resolution, and strength semantics remain outside the sampled proof scope. Four-state witness archives use the development replay commands described above. [Four-state replay evidence](../../evidence/r7/profile-check/four-state-counterexample/qualification.json)
