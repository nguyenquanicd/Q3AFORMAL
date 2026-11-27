# RTL-017 Unsupported Shift-Distance Expected Results

**Profile:** Q3A-P0-R0.9.1.

The profile accepts only compile-time, nonnegative shift distances. `p_dynamic_shift` uses an input signal as the distance and must be rejected. `p_negative_shift` uses a signed negative constant and must be rejected. Both diagnostics must identify the source file and line/column, return a nonzero exit code, and produce no `Q3A_BMC_STATUS`, `Q3A_SAT_STATUS`, or induction status. A rejected construct must not be reported as a counterexample or proof result.

`test_bmc_rtl_017_unsupported_shifts.ps1` checks both cases through the source project command. This records the CLI boundary behavior; it does not claim that the frontend rejects these constructs during parsing or lowering, because the implementation currently diagnoses them while encoding the selected query.
