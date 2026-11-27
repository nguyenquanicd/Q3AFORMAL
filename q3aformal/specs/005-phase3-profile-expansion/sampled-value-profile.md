# Guarded sampled-value profile

The Phase 3 development profile adds four sampled-value functions to the existing one-clock, two-valued SystemVerilog Assertions (SVA) model. It uses profile `Q3A-SAMPLED-VALUE-DEVELOPMENT` so project inputs, proof queries, and archived model identity identify the expanded semantics.

| Form | Predicate evaluated after history becomes available |
| --- | --- |
| `$stable(e)` | All sampled bits of `e` equal the corresponding prior bits. |
| `$changed(e)` | At least one sampled bit of `e` differs from its prior value. |
| `$rose(e)` | The least significant bit of `e` was 0 and is now 1. |
| `$fell(e)` | The least significant bit of `e` was 1 and is now 0. |

Bit significance follows the normalized packed representation, including ascending declarations. Each function takes one expression and inherits the assertion clock. Nesting consumes one more sample at each nested sampled-value operation. Existing sequence-relative history tracking applies. Property terms with unavailable history are guarded by Q3AFormal's two-valued policy. The Institute of Electrical and Electronics Engineers (IEEE) standard defines startup sampling for SystemVerilog across its supported data types. Treat this profile's guarded startup as a documented scope limit when interpreting a proof. [IEEE Std 1800-2017, Â§16.9.3 and Annex F.3.4.4](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

## Bit-vector assertion functions

The source build of the development profile also accepts three single-argument functions over two-valued packed expressions of width 1–64.

| Form | Result |
| --- | --- |
| `$onehot(e)` | One bit is set. |
| `$onehot0(e)` | Zero or one bit is set. |
| `$countones(e)` | The number of set bits as a signed 32-bit integer. |

The lowerer emits one Transition Intermediate Representation (T-IR) node and retains its operand once. The Boolean Satisfiability (SAT) encoder counts set bits with a balanced adder tree. For one-hot predicates it tracks whether any set bit or a second set bit has been encountered. The independent replay evaluator counts set bits by repeatedly clearing the lowest set bit. A nested history expression retains the sampled-value guard. The functions are admitted in assertion, assumption, and cover expressions in this development profile. [IEEE Std 1800-2017, §20.9](https://fpga.mit.edu/6205/_static/F25/documentation/1800-2017.pdf)

The bit-vector regression exhaustively checks all 32 five-bit values against an independent RTL lookup table. It also checks scalar operands, a 64-bit result of 64, signed arithmetic, and history validity. All eight safety certificates revalidate from source. Both zero-vector witnesses replay from source. [Bit-vector regression](test_bit_vector_functions.ps1) · [Windows qualification](../../evidence/p23-vector-build/qualification.json)

For one assertion with three nested counts on a 64-bit operand, the same source and manifest produced a 2,892-byte model with 12 serialized expression nodes. The expanded build produced 101,192,302 bytes with 792,768 nodes. This comparison counts serialized model bytes. [Size comparison](../../evidence/p23-compact-archive-qualification/model-size-comparison.json) · [Reproducible regression](test_compact_bit_vector.ps1)

For the same input, three Windows process runs per build put the median peak working set at 437.04 MiB for expanded lowering and 10.84 MiB for compact lowering. Microsoft Windows reported these process high-water counters through the process handle. This development measurement covers source lowering and model serialization on one fixture. [Raw memory comparison](../../evidence/p23-compact-archive-qualification/process-memory-comparison.json) · [Windows process counters](https://learn.microsoft.com/en-us/windows/desktop/api/psapi/ns-psapi-process_memory_counters)

The compact representation changes the model digest for projects that use the bit-vector functions. Use the recorded originating executable to reopen evidence generated with the earlier expanded representation. For new evidence, regenerate the proof or trace with the compact build.

## Run on Windows

Build the development executable separately and set `option profile Q3A-SAMPLED-VALUE-DEVELOPMENT` in a version 2 project manifest.

```powershell
.\prototype\source\source_manager\build.ps1 -EnableDevelopmentSampledValues -Output evidence/sampled-values/q3aformal-sourcecheck.exe
$exe = '.\evidence\sampled-values\q3aformal-sourcecheck.exe'
& $exe prove project.q3a --engine pdr --property p_stable --evidence-dir proof
& $exe verify-pdr project.q3a --property p_stable --evidence-dir proof
```

The regression checks Property Directed Reachability (PDR) against independent RTL history registers, a most-significant-bit-only change, a deliberately incorrect assertion, and initial and nested history boundaries. It also checks source-backed archive replay and validates a Deletion Resolution Asymmetric Tautology (DRAT) obligation through the standalone checker. [Regression suite](test_sampled_values.ps1) · [Windows qualification](../../evidence/p3-sampled-dev/conformance-retry/qualification.json)

