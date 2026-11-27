# Expected T-IR — Sequential child output part-selects

**Vector ID:** SM-037  
**Profile:** Q3A-P0-R0.9.1  
**Descending direct/nested tops:** `sequential_part_select_direct_top`, `sequential_part_select_nested_top`  
**Ascending direct/nested tops:** `sequential_part_select_ascending_direct_top`, `sequential_part_select_ascending_nested_top`

Two four-bit stateful child outputs fill an eight-bit parent output through constant part-select connections. Both descending `[7:0]` and ascending `[0:7]` parent ranges are covered. The direct design must contain two distinct four-bit state proxies and one complete eight-bit bus equation. The nested design must preserve the same mapping through `sequential_word_wrapper` and expose instance-qualified properties for each leaf.

For every low/high leaf across both hierarchy shapes and range directions, `p_tracks_previous_input` must return `BOUNDED_PASS` at frame 1. `p_rejects_previous_input` must return `BOUNDED_FAIL` with `Q3A_BMC_REPLAY VALIDATED`. These checks cover the child state transition, part-select mapping, parent bus assembly, `$past` history, and property name/clock propagation. Results apply to the emitted T-IR and do not prove full IEEE 1800 conformance.

Negative manifests require fail-closed behavior for a formal/actual width mismatch, a part-select direction that conflicts with the parent declaration, incomplete parent-bus coverage, and overlapping child output slices. The supported output actual is a constant, direction-matched packed part-select with exact formal width; complete parent coverage is required when multiple child outputs drive a bus. Dynamic/indexed selects and general expression-valued outputs remain outside this slice.
