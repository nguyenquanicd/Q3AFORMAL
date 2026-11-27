# Handshake Transition Oracle

This vector checks the `handshake1_entry` next-state equations independently of the T-IR expression-tree shape.

Let `full`, `data_q`, and inputs denote values sampled immediately before one positive clock edge. Define:

```text
in_ready = !full || out_ready
full_next = rst ? 0 : (in_ready ? in_valid : full)
data_q_next = rst ? 0 : ((in_ready && in_valid) ? in_data : data_q)
```

Both next-state values are calculated from the same pre-edge state and input sample. The reset branch applies on every edge where `rst` is high. When reset is low, `full` holds while not ready, and `data_q` holds unless a valid transfer is accepted.

`test_handshake_transition_oracle.ps1` evaluates the lowered equations for all 4,096 combinations of `full`, `data_q`, `rst`, `in_valid`, `out_ready`, and `in_data`, then compares both results against these independent equations. This is focused transition-conformance evidence for this vector; it does not establish complete T016 or T017 conformance.
