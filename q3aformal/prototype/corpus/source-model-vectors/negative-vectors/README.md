# Expected Diagnostics — Negative RTL Vectors

**Profile:** Q3A-P0-R0.9.1  
**Status:** Inputs and expected profile outcomes. T014 syntax-parser outcomes are recorded in its evidence report. T015 has observed source-located outcomes for unresolved modules, exact-width module-port mismatch, invalid named ports, recursive instantiation, and nonterminating generate. T016 has observed rejection of incomplete `always_comb` assignment, a direct combinational cycle, duplicate continuous and procedural drivers, and continuous-vs-procedural driver conflicts; the focused ownership diagnostics report both driver spans. Assignment-context truncation is legal for the tested continuous assignment vector and is documented under SM-052. Generated/hierarchical and selected-driver interactions plus full T017 conformance remain open.

| Source | Matrix row | Expected pre-proof behavior |
|---|---|---|
| latch_inference_reject.sv | RTL-021 | Reject the incomplete always_comb assignment as outside the no-latch profile; identify the uncovered output path and source span. |
| combinational_loop_reject.sv | RTL-019/RTL-020 | Reject a combinational equation that depends on its own driven output; identify the cycle and source location. |
| multiple_driver_reject.sv | RTL-019 | Reject the output's multiple continuous drivers before transition-model generation; identify both driver spans. |
| selected_duplicate_driver_reject.sv | RTL-019 | Reject duplicate drivers on packed bit offset 1 and report the two assignments to that exact bit, even though a different bit was assigned first. |
| multiple_process_driver_reject.sv | RTL-019 | Reject two `always_comb` processes that drive the same output; report the first and conflicting procedural assignment spans. |
| multiple_sequential_driver_reject.sv | RTL-019 | Reject two same-clock `always_ff` processes that drive the same state signal; report both nonblocking-assignment spans. |
| continuous_comb_driver_reject.sv | RTL-019 | Reject a continuous assignment that conflicts with an `always_comb` driver; report both assignment spans before proof. |
| continuous_sequential_driver_reject.sv | RTL-019 | Reject a continuous assignment that conflicts with an `always_ff` state driver; report both assignment spans before proof. |
| asynchronous_reset_reject.sv | RTL-024 | Reject the asynchronous event control before proof; do not reinterpret it as synchronous reset. |
| blocking_sequential_reject.sv | RTL-022 | Reject a blocking assignment in `always_ff` before transition-model generation; report the assignment at line 7, column 9. |
| unresolved_module_reject.sv | RTL-002 | Reject the unresolved child module before model creation; do not infer a black box. |
| port_width_mismatch_reject.sv | RTL-002 | Reject the 4-bit actual connected to an 8-bit formal port; report instance path, actual/formal widths, and source spans. No implicit resizing is permitted in profile Q3A-P0-R0.9.1. |
| invalid_named_port_reject.sv | RTL-002 | Reject the unknown named port before T-IR generation and identify the instance and source span. |
| recursive_instance_reject.sv | RTL-002 | Reject recursive module instantiation and identify the instance/source location rather than recursing indefinitely. |
| generate_instance_vectors.sv with `ENABLE=0` | RTL-028/RTL-002 | Select the disabled branch and reject its unresolved module; do not inspect or elaborate that branch when `ENABLE=1`. |
| out_of_range_select_reject.sv | RTL-016 | Reject the constant bit index outside the declared packed range before lowering; report the select and declaration spans. |
| unsupported_multiplier_reject.sv | RTL-018 | Reject multiplication as outside the Phase 0 expression subset with an operator-located diagnostic. |
| xz_literal_reject.sv | RTL-009 | Reject X/Z data literals before model generation with the literal's source span. |
| fill_x_reject.sv, fill_z_reject.sv | RTL-007 | Reject unbased unsized X/Z fill literals before lowering; report that only `'0` and `'1` are supported. |
| nonterminating_generate_reject.sv | RTL-029 | Reject a static generate loop whose genvar update does not advance toward a terminating condition. |

These vectors exercise explicit diagnostic policy. T014 parser-stage outcomes are listed in `../../results/t014-parser.md`; they cover grammar checks and syntax-level rejections. T015 hierarchy/generate observations are recorded in `../../results/t015-elaborator-progress.md`. T016 has focused observed rejection evidence for incomplete `always_comb` assignments, direct combinational loops, duplicate continuous/procedural drivers, and continuous-vs-procedural ownership conflicts. Assignment-context truncation is tested as a legal conversion in SM-052. Generated/hierarchical and selected-driver ownership, broader select boundaries, and other remaining semantic rejection behaviors still need implementation or recorded conformance evidence.





