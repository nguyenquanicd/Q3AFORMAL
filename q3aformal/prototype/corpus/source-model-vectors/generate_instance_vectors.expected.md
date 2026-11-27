# Expected Elaboration — Generated Module Instances

**Profile:** Q3A-P0-R0.9.1  
**Top:** `generated_hierarchy_top`

With default `ENABLE=1` and `WIDTH=4`, the elaborator selects `g_enabled.u_flag`, does not resolve the inactive `missing_generated_module`, and expands `g_bits[0].u_bit` through `g_bits[3].u_bit`. Each bit-select actual and formal port is one bit. The hierarchy should contain five active child instances.

With `ENABLE=0`, the selected branch references the absent `missing_generated_module`; elaboration must reject the project with a source-located unresolved-module error. The inactive branch is not a valid fallback implementation.
