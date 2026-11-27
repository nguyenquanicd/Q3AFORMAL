# Q3AFormal Source Manager

The source manager reads a Q3A project manifest, validates the project boundary, captures source bytes, and computes deterministic SHA-256 identities. The `q3aformal-sourcecheck` executable provides source inspection, bounded model checking (BMC), k-induction, and Property Directed Reachability (PDR) for the supported profile. Finite sequence forms include exact and ranged delays and positive consecutive repetition of supported scalar and compound operands. History-validity guards are evaluated at the associated sample. The supported placement and engine limits are documented in the conformance evidence. [Published language profile](../../../specs/003-phase1-block-mvp/plan.md#supported-phase-1-language-profile) · [Conformance matrix](../../corpus/conformance-matrix.csv) · [Sequence alignment oracle](../../tests/test_sva_sequence_alignment_oracle.ps1)

## Manifest format

Phase 1 accepts `Q3AFORMAL_PROJECT 2` alongside the Phase 0 format. Both versions use the same source resolution, elaboration, and source-set hashing pipeline. A version 2 manifest can select the run defaults.

```text
Q3AFORMAL_PROJECT 2
top counter4_pass
source systemverilog "corpus/source-model-vectors/counter4_pass.sv"
option profile Q3A-P0-R0.9.1
option engine induction
option property p_wraps_to_zero
option depth 1
```

Version 2 accepts `top`, `parameter NAME VALUE`, `define NAME [TOKENS]`, `include_dir "PATH"`, `source systemverilog "PATH"`, and `property_source systemverilog "PATH"`. The two source directives add ordered SystemVerilog compilation units. The supported options are `profile`, `engine`, `property`, and `depth`. Project files with unsupported fields or source languages produce a file-and-line diagnostic. Manifest reset overrides remain pending. The synchronous reset semantics remain those of the active RTL profile.

A property source can declare an input-only monitor module or contain compilation-unit `bind` directives. `bind leaf monitor u_checks (.sample_clk(clk), .observed(data));` attaches the monitor to every elaborated instance of `leaf`. `bind top.g_lane[1].u_leaf monitor u_checks (clk, data);` targets one elaborated instance. Connections and parameter overrides resolve in the target's lexical scope. Use exact port widths and a monitor sampling clock connected to the design's supported positive-edge clock. Bundle replay archives both the directive and the monitor source. Target instance lists and nonliteral generated indices are outside this binding profile.

A property source may also hold standalone named declarations and concurrent checks. Inline standalone checks require a label and named declarations resolve within their own compilation unit. Use a top-relative signal path such as `g_lane[1].u_leaf.valid` or an explicit root-qualified path such as `$root.top.g_lane[1].u_leaf.valid`. Generated instance indices use nonnegative decimal literals. The sampling event must resolve to the design's supported one-bit positive-edge input. Sources, model signal references and witness frames remain available when reopening the bundle.

`--parse-project` parses resolved compilation units using the same macro and include settings as a proof run and reports bind directives alongside modules. `properties <project.q3a> [--parameter NAME VALUE ...]` accepts the same parameter overrides as `prove`. Compare the resulting `source_set_sha256` with the bundle's source-set identity when reviewing a proof configuration.

`--preprocess-project <project.q3a>` writes a JSON revision 1 report for a version 2 manifest. Each unit lists the full ordered token stream and its macro expansions. The source-set digest matches a proof run using the same manifest settings. The stream includes the end marker. File line and column are one-based, while byte offsets and token indices are zero-based.

Each expansion contains the outer invocation, the visited macro definitions in evaluation order, and a half-open token range `[output_begin, output_end)`. Include operands and empty replacements have equal range endpoints. Included tokens retain their header locations, and manifest macro definitions use the synthetic location `<manifest macro>`. The command records up to one million macro expansion steps per compilation unit, including its active headers. Proof runs do not collect these diagnostic records.

Manifest definitions seed a shared object-like macro environment before the first compilation unit. Source directives support object-like and function-like definitions, undefinition and conditional compilation. Source definitions may span physical lines when a backslash immediately precedes the LF or CRLF line ending. Function-like source macros support default arguments, nested calls and commas inside balanced argument delimiters. Omitted or empty arguments use the corresponding default when one is present. Macro definitions remain visible to later files in manifest order.

A version 2 compilation unit may contain only definitions, includes or comments. Such a unit contributes no declarations, and its preprocessor effects remain visible in source order. Source-backed bundle verification uses the same policy. The project must still elaborate its selected top. Version 1 manifests and the standalone parser retain their empty-input rejection. Conditional blocks must close within each physical file. The source scanner tokenizes files before choosing active branches, so inactive branches must remain lexically valid.

Within a macro expansion, a double backtick joins the expanded operands into one lexical token. This supports identifiers, based literals and a pasted name that is then expanded as a macro. Missing operands and results that do not form one token produce a source-located error.

Single-line macro quotation creates a string from a template after expanding referenced arguments and nested macros. Literal spaces and punctuation remain in the result, and a double backtick separates template pieces without appearing in the output. The supported use is an include operand. Multiline quotation and the special escaped-quotation syntax remain outside the profile.

An active include may use a macro operand when expansion yields exactly one quoted relative path. Resolution starts at the directory of the file containing the include directive and proceeds through the manifest's ordered include directories. Bundle verification re-expands the operand using the archived macro settings, then resolves it within the archived sources and headers.

A quoted SystemVerilog include is resolved from the including file's directory first and then from the ordered `include_dir` directories. Paths are relative to the project and must stay within its root. Active nested includes share the macro environment and retain file-and-line locations. Unguarded cycles exceed the supported nesting limit of 32. Bundle identity includes the declared search order and the exact bytes of every active header in first-use order. Verification resolves the includes from the archived snapshot, and debug displays the header for included assertions.

Manifest definitions are hashed in name order as part of the resolved source set and stored in result bundles. The verifier applies the same macro environment to archived sources before regenerating the lowered model. Version 1 and projects without manifest definitions retain their previous source-set hash format.

Run a manifest-selected query with `prove <project.q3a>` and the required artifact option for the engine. Bounded model checking (BMC) requires `option depth`. Add `--output-prefix <prefix>` for induction or `--evidence-dir <directory>` for property-directed reachability (PDR). The explicit `--engine` and `--property` command form supplies its own run settings. The result bundle records the input manifest schema and exact manifest bytes. The resolved source-set digest excludes run defaults.

Set `--parameter NAME VALUE` immediately after the manifest argument to override a top-level parameter in a product invocation. The precedence is command line, manifest, then source default. Repeat the same arguments when checking a PDR certificate for an overridden project.

### Phase 0 format

The manifest is UTF-8 text. Paths are quoted and relative to the manifest's directory. Source declaration order is retained because compilation order can affect language semantics.

```text
Q3AFORMAL_PROJECT 1
top counter4_pass
source "corpus/source-model-vectors/counter4_pass.sv"
```

Supported directives are:

- `top IDENTIFIER` exactly once.
- `parameter IDENTIFIER VALUE` zero or more times; duplicate names are rejected.
- `source "RELATIVE_PATH"` one or more times; duplicate paths are rejected.

Blank lines and lines beginning with `#` are ignored. The project root is the manifest directory. Absolute paths, paths containing `..`, symlinks resolving outside the project root, missing files, and non-regular files are rejected.

Each source hash covers its exact input bytes. The project input hash covers the semantic profile ID, top-module name, name-sorted parameter assignments, and source path/hash pairs in declaration order. Fields use length-prefixed canonical encoding to avoid delimiter ambiguity. The CLI emits only manifest-relative source paths and quotes paths that contain spaces.

## Build and run on Windows

Use a C++17 MinGW-w64 compiler and the Windows BCrypt system library for SHA-256:

From the `q3aformal` directory:

```powershell
.\prototype\source\source_manager\build.ps1 -Compiler '<path-to-g++.exe>'
.\prototype\bin\q3aformal-sourcecheck.exe .\prototype\counter4.q3a
.\prototype\bin\q3aformal-sourcecheck.exe --lex .\prototype\corpus\source-model-vectors\counter4_pass.sv
.\prototype\bin\q3aformal-sourcecheck.exe --parse .\prototype\corpus\source-model-vectors\counter4_pass.sv
.\prototype\bin\q3aformal-sourcecheck.exe --parse-project .\prototype\supported-parse.q3a
.\prototype\bin\q3aformal-sourcecheck.exe --elaborate-project .\prototype\parameterized-hierarchy.q3a
.\prototype\bin\q3aformal-sourcecheck.exe --lower-project .\prototype\lower-operators.q3a
.\prototype\bin\q3aformal-sourcecheck.exe --transition-cnf .\prototype\lower-multi-process.q3a --frames 1
.\prototype\bin\q3aformal-sourcecheck.exe --bmc .\prototype\bmc-scalar.q3a --property p_can_fail --frames 3
.\prototype\bin\q3aformal-sourcecheck.exe --sat-dimacs .\path\problem.cnf --decision-limit 100000
```

The repository sample manifest is `prototype/counter4.q3a`. The build script writes the executable to `prototype/bin/`.

## Current limits

The parser commands provide syntax validation only. The partial elaborator recursively resolves hierarchy, parameter overrides, active static-generate instances, and exact connected-port widths for the implemented expression subset. `--lower-project` emits a prototype JSON T-IR slice for supported continuous assignments, limited single-clock `always_ff`, limited `always_comb`/`case`/`casez`, and a restricted SVA property subset with symbolic sequence automata. It can recursively flatten parameterized or unparameterized module trees with supported continuous/combinational/sequential logic and static generate-if/for scopes containing module instances or active whole-signal/constant bit/part-select continuous assignments with genvar substitution; complete selected bit/part-select sets become one full-width equation, while duplicate/partial coverage fails closed; the SM-031 regression evaluates both packed directions, direct/generated part-selects, all 16 four-bit inputs, a parameterized child, a bounded SAT pass, and an independently replayed false-property counterexample; active scoped logic/bit declarations are lowered in static generate blocks with focused top-level and child evidence; generate-local parameters, declaration initializers, and unscoped generated declarations remain unsupported; child output ports may connect to whole parent signals or constant packed-parent bit/part-selects with exact widths, direction-matched bounds, and complete bus coverage; part-select bounds must be constant, in range, and match the declaration direction, and generated child paths retain resolved genvar and parameter values. Child input expressions must match formal widths. Child output actuals support whole parent-scope signals or constant, direction-matched packed-parent bit/part-selects whose widths exactly match the formal output. Selected bits must cover a driven parent bus exactly once. Direct/wrapped sequential part-select outputs have guarded-history pass/replay coverage in SM-037; direct/wrapped combinational part-select outputs have assembled-bus bounded-property coverage in SM-038. Sequential child states remain distinct per-instance signals. `$past` is represented with generated history-data shift equations and validity-state equations. `--transition-cnf <project.q3a> --frames N` encodes the supported T-IR transition relation over frames 0..N, including combinational equations, simultaneous next-state equations, and false initialization for generated history-valid state. The output includes signal/frame/bit-to-DIMACS-variable comments and can be passed to `--sat-dimacs`. `--bmc <project.q3a> --property <name> --frames N` checks scalar assertions, standalone linear sequence assertions, and linear finite implication sequences (`|->`, `|=>`) with constant delays, finite delay ranges ##[m:n], and positive bounded consecutive repetition, under scalar, linear sequence, or supported implication assumptions. It reports vacuity and incomplete assertion-boundary obligations. Scalar, linear-sequence, and linear-implication cover goals use bounded reachability; an implication cover requires an in-bound antecedent and consequent match, and `COVERED` is reported only after the decoded witness passes independent replay. A cover miss returns `UNKNOWN` with `NOT_FOUND_WITHIN_BOUND`, never `UNREACHABLE`. Assertion failures also include decoded traces and are independently replayed. Add `--vcd <path>` to save a replay-validated Value Change Dump (VCD), or `--html <path>` to save a self-contained offline waveform viewer from the same validated witness. The HTML viewer supports signal-name filtering, a frame cursor, one-bit waveforms, and vector values; it renders up to 64 matching signals at once. Both formats use discrete sample frames at 1 ns per frame and omit abstract clock signals. Each exporter refuses to overwrite the project manifest or RTL sources. If no validated witness exists, neither output file is created. These are bounded results and do not prove unbounded correctness. Raw unsupported sequence/property forms are rejected; full IEEE coverage counters for vacuous implication success are not implemented. Sequence expansion is capped at 4,096 paths and 1,000,000 predicate-frame evaluations. Whole-signal and constant bit/part-select assignments in active static generate scopes are lowered with genvar substitution; selected bit/part-select sets require exact complete coverage with no duplicates. Generate-local parameters, declaration initializers, unscoped generated declarations, dynamic/indexed child output selects, expression-valued output actuals, unsupported property/process forms, latches, combinational cycles, multiple drivers, and assignment width conversions remain rejected except for RTL-005 literal-only expressions and supported mixed signal/unsized-decimal unary/binary +/− trees; other mismatches fail closed. Inline and named child assert/assume/cover properties are flattened recursively through nested instances with instance-qualified names, mapped one-bit top-level clocks, port-expression substitution, and namespaced guarded `$past` state. The supported preprocessor forms are listed in [Manifest format](#manifest-format). IEEE 1800 sizing, type semantics, transition lowering and SVA monitor semantics remain limited to the published conformance profile. A successful parse, partial elaboration, standalone SAT result, transition-relation SAT result, or T-IR slice must not be interpreted as proof support.

`--prove-inductive <project.q3a> --property <name> [--k <depth>] --output-prefix <prefix>` constructs k-induction base-prefix and step obligations, defaulting to `k=1`. It accepts scalar predicates and same-sample sequences joined by `##0`, plus standalone scalar assertion sequences and assertion implication operands with fixed delays or finite bounded delay ranges (##[m:n]) and positive bounded repetition ranges on single linear automata. Each sequence path expansion is capped at 4096 paths. A non-implication sequence assertion must match at every start frame; when repetition offers multiple lengths, any complete path may satisfy the sequence. The maximum property horizon plus `k` must not exceed 10000 transitions; for implications, the horizon includes the largest antecedent match offset, the `|->`/`|=>` delta, and the largest consequent match offset. Delayed assertions cannot use guarded `$past`; same-sample overlapped predicates may retain the property-level guard. Assumptions may use these bounded sequences and implications; only starts whose complete maximum horizon fits the finite proof window are constrained. Unbounded delay ranges remain unsupported. For depth k, base checks property starts 0..k-1; step assumes the property on starts 0..k-1 and checks start k. SAT witnesses are decoded and independently replayed against T-IR equations, assumptions, and base/step semantics before they are saved. A replayed base counterexample prints `Q3A_INDUCTION_STATUS FAIL`; a replayed step countermodel is `NOT_<k>_INDUCTIVE` because it may be unreachable. Passing both obligations prints `Q3A_INDUCTION_STATUS PROVEN` with `GENERATED_TIR_MODEL` scope. Delayed assumptions with guarded `$past`, unsupported automata, and other temporal assumptions are rejected; this result does not prove that frontend/lowering matches IEEE 1800 semantics. See `prototype/checker/README.md` for the proof checker boundary.

## Memory policy

On Windows, each formal run samples available physical memory and the process's private committed bytes. The default process ceiling is based on the process baseline plus half of the physical memory available at startup. Guarded allocations also recheck current available memory and preserve a host reserve of up to 512 MiB (one quarter of startup-available memory, when smaller). These checks respond to memory consumed by other applications during a run; installed RAM is not treated as available RAM.

Set `Q3A_MEMORY_LIMIT_MIB` to impose a stricter absolute process-private-commit ceiling in MiB. Set `Q3A_MEMORY_RESERVE_MIB` to override the default physical-memory reserve in MiB, leaving that amount available to Windows and other applications. Both values must be positive integers. For example, in PowerShell:

```powershell
$env:Q3A_MEMORY_LIMIT_MIB = '4096'
$env:Q3A_MEMORY_RESERVE_MIB = '2048'
& .\prototype\bin\q3aformal-sourcecheck.exe --bmc .\prototype\bmc-scalar.q3a --property p_can_fail --frames 100
Remove-Item Env:Q3A_MEMORY_LIMIT_MIB, Env:Q3A_MEMORY_RESERVE_MIB
```

If a monitored resource limit is reached, BMC or induction returns `UNKNOWN` without publishing partial proof evidence. Induction streams both conjunctive normal form (CNF) queries and proof records to disk and reopens the staged files for checking and export. Set `Q3A_SCRATCH_DIR` to an existing writable directory with sufficient capacity to put transient induction files on a separate drive. The default location is beside `--output-prefix`. Normal completion and handled errors clean up the transient files. Keep space available for the requested outputs and bundle as well. The optional cache streams CNF and proof files during storage and lookup.

The active Boolean satisfiability (SAT) clause database and search state remain in RAM. Lower BMC frame counts or induction depth reduce formula size and can change the checked temporal scope or whether a proof is found.

## Result bundles

Add `--bundle-dir <new-directory>` to `--bmc` or `--prove-inductive` to preserve a versioned evidence bundle. The bundle includes the exact project manifest and RTL snapshot, canonical T-IR, exact CNF queries, run/property summary, artifact hashes, resource limits, assumptions and reset policy, build/component fingerprints, and checker identity. BMC bundles include a trace JSON after successful independent replay and include a VCD when `--vcd` is also requested. Induction bundles include the checked base/step proof artifacts and any replay-validated witnesses. Contradictory model/assumption and feasibility `UNKNOWN` results preserve their feasibility CNF.

The schema is `Q3A-RUN-BUNDLE-1`. The bundle directory must not already exist. `manifest.sha256` protects the manifest bytes; every listed artifact has its own SHA-256 in `manifest.json`. `--verify-bundle <directory>` checks manifest, source/model/query identities, artifact hashes and DRAT proof artifacts only when checker ID, schema, and component source fingerprint match. For a BMC bundle with a saved validated witness, the verifier reconstructs supported serialized T-IR and independently replays its equations, assumptions, and property, then reports `REVALIDATED` with scope `REPLAYED_BMC_WITNESS_FOR_SERIALIZED_TIR`. For a no-witness `BOUNDED_PASS` assertion or `UNKNOWN` cover miss, it can regenerate and byte-compare the bounded CNF, check model feasibility, and reexecute the UNSAT query when the SAT bit-blaster fingerprint matches; the cover result remains bounded, not `UNREACHABLE`. These checks do not validate RTL-to-T-IR translation. Evidence without compatible revalidation remains `HISTORIC`. Optional identity-bound caching is implemented for checked DRAT artifacts from supported k-induction queries; BMC results and SAT witnesses remain uncached. See [Proof Cache](../cache/README.md). See [Result Bundles](../bundle/README.md) for layout and current limits.
