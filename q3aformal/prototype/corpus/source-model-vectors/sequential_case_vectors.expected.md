# Expected T-IR Behavior — sequential_case_vectors.sv

**Vector ID:** SM-017  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check exact `case` lowering inside `always_ff`, source-order case priority, multi-label matching, and nonblocking assignment ordering.

## Expected transition

At each positive edge of `clk`:

- `select == 2'b00`: `result_next = value_b`. The second nonblocking assignment in that case branch overrides the earlier assignment to `value_a`.
- `select == 2'b01` or `select == 2'b10`: `result_next = value_a`.
- Otherwise (`select == 2'b11`): `result_next = result`, so the register holds its current value.

The equivalent priority expression is:

```text
result_next = (select == 2'b00) ? value_b
            : ((select == 2'b01) || (select == 2'b10)) ? value_a
            : result
```

This is an authored expected result for T016 lowering. Independent frame-by-frame comparison and conformance status remain T017 work.
