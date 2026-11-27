# Nested `$past` Expected History

For sampled input sequence `a[0], a[1], ...`, the generated stages must satisfy:

```text
history_stage_0[t] = a[t - 1]       for t >= 1
history_stage_1[t] = a[t - 2]       for t >= 2
history_valid[t]  = (t >= 2)
```

The initial values of history data are irrelevant while the two-sample validity guard is false. `test_sva_history_frame_oracle.ps1` checks the two shifts over a six-frame input sequence and verifies that a one-stage history-valid state advances through asserted and reasserted RTL reset samples. These checks validate the generated history-state equations for these vectors; they do not validate complete SystemVerilog Assertions semantics.
