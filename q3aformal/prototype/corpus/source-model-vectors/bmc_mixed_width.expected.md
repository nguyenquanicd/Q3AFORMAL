# Expected Results — `bmc_mixed_width.sv`

**Vector ID:** SM-050  
**Profile:** Q3A-P0-R0.9.1  
**Matrix rows:** RTL-011, RTL-012, RTL-013, RTL-014

The module combines three-bit and two-bit unsigned and signed operands. References explicitly zero-extend unsigned operands and sign-extend signed operands to three bits before arithmetic, bitwise, relational/equality, or conditional comparison. Arithmetic results retain the selected three-bit result width. The signed conditional reference sign-extends the two-bit signed branch when selected.

`test_bmc_mixed_width.ps1` checks six source-level assertions for unsigned relational, equality, XOR, signed relational, signed addition, and signed conditional extension. Each must pass nonvacuously. The mixed-width SAT and replay regressions separately enumerate the approved three-bit/two-bit value and signedness combinations, including addition/subtraction, bitwise and comparison operators, and both conditional branches.

The vector documents representative source-to-T-IR behavior; it does not establish all SystemVerilog context-determined sizing, arbitrary widths, multiplication/division, four-state comparison, or source-level vectors for every mixed-signedness form.
