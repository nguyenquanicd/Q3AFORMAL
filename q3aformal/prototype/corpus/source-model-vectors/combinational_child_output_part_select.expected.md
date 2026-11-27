# Expected T-IR — Combinational child output part-selects

**Vector ID:** SM-038  
**Profile:** Q3A-P0-R0.9.1  
**Descending direct/nested tops:** `combinational_part_select_direct_top`, `combinational_part_select_nested_top`  
**Ascending direct/nested tops:** `combinational_part_select_ascending_direct_top`, `combinational_part_select_ascending_nested_top`

The direct top connects two four-bit combinational child outputs to the low and high slices of an eight-bit parent bus. The nested top performs the same connections through `combinational_word_wrapper`. Both descending `[7:0]` and ascending `[0:7]` parent declarations are covered. Each hierarchy must lower to one complete eight-bit `q` equation without retaining temporary output proxies.

For each of the four top/range combinations, `p_maps_outputs` must return `BOUNDED_PASS` at frame 0. The assertion compares the assembled bus against `d ^ 8'hAA`, checking child equations, slice ordering, and parent bus assembly through the bounded T-IR/SAT path. This is focused translation evidence, not proof of full IEEE 1800 conformance or unbounded correctness.

The output connections use constant, direction-matched packed part-selects whose widths exactly match the child formal. Dynamic/indexed selections, arbitrary expression-valued output actuals, and broader hierarchy source-to-model conformance remain unsupported or open.
