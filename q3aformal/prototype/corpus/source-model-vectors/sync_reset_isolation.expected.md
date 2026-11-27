# Expected Results — `sync_reset_isolation.sv`

**Vector ID:** SM-044  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check that a synchronous reset branch updates only the state explicitly assigned in that branch, while another state element in the same clocked process continues to capture its input.

For each positive-edge transition, with all right-hand sides sampled from the pre-edge state:

```text
reset_q_next = rst ? 0 : data_in
free_q_next  = data_in
```

The independent oracle checks all 16 combinations of old state, reset, and data. It also simulates six consecutive frames with reset held, released, and reasserted (`rst = 1,1,0,0,1,0`). `free_q` must follow `data_in` on every frame, including frames where reset is asserted.

This evidence is limited to a single positive-edge process, an active-high synchronous reset, and the tested two-state assignments. Asynchronous reset and four-state reset behavior remain unsupported.
