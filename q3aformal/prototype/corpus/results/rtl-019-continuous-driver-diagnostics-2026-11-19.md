# RTL-019 Continuous-Driver Diagnostic Evidence

**Date:** 2026-11-20  
**Profile:** Q3A-P0-R0.9.1  
**Matrix status:** Supported for the tested bounded top-level driver-ownership profile

## Scope

This increment checks a focused top-level driver-ownership slice: one valid exact-width continuous driver, a legal sized-literal assignment requiring truncation, duplicate continuous assignments, two procedural processes driving one output, and continuous-vs-`always_comb`/`always_ff` conflicts. The truncation case must lower to an explicit `assignment_resize` and pass its source property. Each ownership conflict is rejected before proof and reports the first and conflicting assignment locations. An 8-bit sized literal assigned to a 4-bit target is legal assignment-context conversion in this profile; module ports retain their separate exact-width rule.

## Evidence

| Case | Inputs | Observed result |
|---|---|---|
| Positive | `rtl_single_driver.sv`, `rtl-single-driver.q3a` | `--lower-project` succeeds. T-IR contains one 4-bit equation `y = a` with a 4-bit signal expression. |
| Assignment-context resize | `continuous_assignment_resize.sv`, `continuous-assignment-resize.q3a` | Lowering produces one 4-bit `assignment_resize` over the 8-bit literal at source line 5; `p_assignment_truncation` passes nonvacuously at frame 0. |
| Duplicate driver | `multiple_driver_reject.sv`, `reject-multiple-driver.q3a` | Lowering exits with an error before proof. The diagnostic identifies the first driver at `multiple_driver_reject.sv:6:5` and the conflict at `multiple_driver_reject.sv:7:5`. |
| Two procedural drivers | `multiple_process_driver_reject.sv`, `reject-multiple-process-driver.q3a` | Two `always_comb` processes driving `y` reject before proof with spans `multiple_process_driver_reject.sv:7:5` and `multiple_process_driver_reject.sv:10:5`. |
| Two sequential drivers | `multiple_sequential_driver_reject.sv`, `reject-multiple-sequential-driver.q3a` | Two same-clock `always_ff` processes driving `y` reject before proof with spans `multiple_sequential_driver_reject.sv:8:5` and `multiple_sequential_driver_reject.sv:11:5`. |
| Continuous/procedural conflict | `continuous_comb_driver_reject.sv`, `reject-continuous-comb-driver.q3a` | Continuous assignment vs. `always_comb` rejects before proof with spans `continuous_comb_driver_reject.sv:6:5` and `continuous_comb_driver_reject.sv:8:1`. |
| Continuous/sequential conflict | `continuous_sequential_driver_reject.sv`, `reject-continuous-sequential-driver.q3a` | Continuous assignment vs. `always_ff` rejects before proof with spans `continuous_sequential_driver_reject.sv:7:5` and `continuous_sequential_driver_reject.sv:9:1`. |
| Duplicate selected-bit driver | `selected_duplicate_driver_reject.sv`, `reject-selected-duplicate-driver.q3a` | A different packed bit is driven first; duplicate packed offset 1 rejects with the correct per-bit source spans `selected_duplicate_driver_reject.sv:7:5` and `selected_duplicate_driver_reject.sv:8:5`. |

## Reproduction

From the `q3aformal` directory:

```powershell
.\prototype\source\source_manager\build.ps1
.\prototype\tests\test_continuous_driver_diagnostics.ps1
```

`test_continuous_driver_diagnostics.ps1` passed on 2026-11-20. The regression inspects exact-width T-IR, assignment-resize T-IR and nonvacuous BMC behavior, and pre-proof rejection with both source spans for each ownership conflict.

## Limits and next work

The tested profile covers module-scope continuous assignments, top-level `always_comb`/`always_ff` processes, assignment-context truncation for the focused literal case, and duplicate static bit-select assignments with per-bit first-driver tracking. RTL-019 is **Supported for this bounded profile**. Generated/hierarchical child-output ownership, broader part-select overlap combinations, other assignment-sizing boundaries, and complete source-to-model evaluation remain open under T016/T017.
