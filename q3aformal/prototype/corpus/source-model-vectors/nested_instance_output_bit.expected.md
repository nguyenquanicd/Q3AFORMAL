# Expected T016 Result — Nested Child Output Bit-Selects

The `nested_instance_output_bit_top` model must contain one full-width, four-bit combinational equation for `y`. The equation must preserve the behavior of four generated wrappers, each of which forwards its input through a nested child instance and a wrapper-local signal. The assertion `p_nested_output_map` must return `BOUNDED_PASS` at frame 0.

Each wrapper's local signal must retain its generated hierarchical path. Temporary output-bit proxy names must be removed from the serialized T-IR after their expressions are mapped into the parent bus. This fixture demonstrates the supported combinational direct/nested output mapping slice; it does not establish general hierarchy or SVA conformance.
