# Sequential Child State Expected Behavior

**Vector ID:** SM-022  
**Profile:** Q3A-P0-R0.9.1, specification revision 0.10

The child owns one one-bit state signal `value_q`, clocked by the connected top-level `clk`. Its synchronous transition is:

```text
value_q_next = rst ? 0 : (enable ? !value_q : value_q)
value = value_q
```

The flattened T-IR names the state `u_toggle.value_q`, marks it as `state`, binds the model clock to top-level `clk`, and drives the parent `value` output from that state. `test_hierarchy_lowering.ps1` checks all eight combinations of old state, reset, and enable against the reference transition equation.

This vector covers one direct unparameterized child with one positive-edge clock and a supported synchronous process. Multiple clocks, generated state, parameters, and broader independent process conformance remain open.

## Vector SM-024 — two instances of one stateful child

The `hierarchy_multiple_instances_top` top instantiates the same `hierarchy_toggle_leaf` module twice, as `u_left` and `u_right`. Both instances share `clk`, `rst`, and `enable`, but each owns separate state. Their expected transitions are:

```text
u_left.value_q_next  = rst ? 0 : (enable ? !u_left.value_q  : u_left.value_q)
u_right.value_q_next = rst ? 0 : (enable ? !u_right.value_q : u_right.value_q)
left_value  = u_left.value_q
right_value = u_right.value_q
```

The flattened T-IR must contain two distinct state signals and two next-state equations, with each equation referring only to its own instance state plus the shared top-level controls. `test_hierarchy_lowering.ps1` checks all 16 combinations of both old states, reset, and enable, and confirms the two child outputs drive separate top-level outputs. This checks instance-path separation and prevents state aliasing between two copies of the same child module; it does not establish broader hierarchy conformance.

## Vector SM-026 — nested child state

`hierarchy_nested_toggle_top` instantiates `hierarchy_nested_toggle_middle`, which instantiates the stateful `hierarchy_toggle_leaf`. The state path must be `u_middle.u_toggle.value_q`; the nested leaf clock, reset, enable, and output connect through the middle-level ports to the top-level signals.

```text
u_middle.u_toggle.value_q_next = rst ? 0 :
    (enable ? !u_middle.u_toggle.value_q : u_middle.u_toggle.value_q)
value = u_middle.u_toggle.value_q
```

`test_hierarchy_lowering.ps1` checks the full path, state role, top-level `clk` binding, output equation, and all eight state/reset/enable combinations. This verifies nested flattening for a supported sequential leaf; it does not certify all hierarchy mapping or transition semantics.
