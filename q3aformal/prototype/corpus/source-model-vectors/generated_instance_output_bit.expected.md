# Expected T016 Result — Generated Child Output Bit-Selects

## Direct generated lanes

For both `generated_instance_output_bit_top` and `generated_instance_output_bit_ascending_top`, the lowered model must contain exactly one combinational equation for `y` with width 4. The equation must implement `y == a` for all 16 four-bit input values, even though the declarations use opposite packed-range directions. The identity property must return `BOUNDED_PASS` at frame 0.

The intentionally false property `p_output_wrong` in the descending-range top must return `BOUNDED_FAIL` and a replay-validated counterexample.

## Fail-closed cases

Lowering must reject partial bus coverage, duplicate child output connections to one bit, conflict with a whole-signal assignment, a dynamic index, an out-of-range index, and a part-select actual. It must not leave generated proxy names in serialized T-IR.
