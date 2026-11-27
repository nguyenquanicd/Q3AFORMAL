# Expected Elaboration — Parameterized Direct Child Instance

**Profile:** Q3A-P0-R0.9.1  
**Top:** `parameterized_hierarchy_top`  
**Default top parameter:** `WIDTH = 4`

The parent passes its resolved `WIDTH` parameter to `u_leaf.WIDTH`. The leaf defines `DATA_WIDTH = WIDTH` and uses it for its internal signal. The child formal ports `data_in` and `data_out` therefore resolve to four bits and exactly match the parent actual signals. The child then passes that value to `u_leaf.u_passthrough`, whose formal widths also match the leaf's actual signals. Both hierarchy levels are elaborated with no implicit extension or truncation.

When the project overrides the top `WIDTH` to 3, both child parameter values and all connected port widths resolve to 3, and the instance connections remain exact-width matches.

The positional-override top provides the same result using `#(WIDTH)`. The default-parameter top omits an override and resolves the leaf and passthrough widths to their default value of 2. T016 now lowers the three-level parameterized tree and preserves resolved `WIDTH` and `DATA_WIDTH` values in T-IR under the top or fully qualified instance path. The hierarchy regression checks input-to-output identity for every input value at widths 2, 3, and 4.
