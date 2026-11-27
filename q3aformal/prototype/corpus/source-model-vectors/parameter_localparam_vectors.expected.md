# Expected Results — parameter_localparam_vectors.sv

**Vector ID:** SM-010  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check constant parameter override, localparam evaluation, resolved port widths, and parameter-dependent expression elaboration.

## Configuration A — default WIDTH=4

- Resolve WIDTH=4 and DOUBLE_WIDTH=8 before model construction.
- data_in has width 4; data_twice has width 8.
- For data_in=4'hA, expected data_twice=8'hAA and width_is_four=1.

## Configuration B — WIDTH=3 override

- Resolve WIDTH=3 and DOUBLE_WIDTH=6 before model construction.
- data_in has width 3; data_twice has width 6.
- For data_in=3'b101, expected data_twice=6'b101101 and width_is_four=0.

## Expected elaborated/T-IR properties

Configuration C overrides WIDTH to 32. DOUBLE_WIDTH is 64, data_in is 32 bits, data_twice is 64 bits, and width_is_four is zero.

`test_parameter_identity_conformance.ps1` checks all three configurations. It recomputes the input SHA-256 from the profile, top module, override entries and exact source bytes, verifies source locations and lowered types, and compares repeated serialized models byte for byte.

- The parameter override is part of the elaboration configuration and model identity.
- DOUBLE_WIDTH is a deterministic compile-time constant computed as WIDTH + WIDTH, using only the Phase 0 approved arithmetic operators.
- Port widths are resolved from the selected parameter value before expressions are lowered.
- No runtime state is created for parameters or localparams.

