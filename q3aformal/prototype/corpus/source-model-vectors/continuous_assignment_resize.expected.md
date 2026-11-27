# Expected Results — `continuous_assignment_resize.sv`

**Vector ID:** SM-052  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** RTL-019

The 8-bit based literal `8'd1` assigned to a 4-bit output is legal assignment-context truncation. T-IR must preserve the 8-bit literal beneath an `assignment_resize` node whose result and target width are 4 bits. The source assertion `p_assignment_truncation` must pass nonvacuously at frame 0 with `y == 4'h1`.

`test_continuous_driver_diagnostics.ps1` checks the T-IR widths, expression kind, source mapping, and bounded property. This is an assignment-sizing case, not a module-port connection; the profile's exact-width rule applies to connected module ports.
