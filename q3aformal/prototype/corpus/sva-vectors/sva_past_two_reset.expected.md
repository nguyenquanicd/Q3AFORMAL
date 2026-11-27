# Expected Results — sva_past_two_reset.sv

**Profile:** `Q3A-P0-R0.9.1`

The module has a synchronous reset on state `q` and assumes `rst` high at every positive-edge sample. The assumption makes reset cross both history warm-up boundaries in the BMC checks.

- `p_past_one` is suppressed at sample 0 because no prior sample exists. It becomes active at sample 1.
- `p_past_two` is suppressed at samples 0 and 1. It becomes active at sample 2 and reads `a` sampled at frame 0.
- History-data and validity state advance while `rst` is asserted. Resetting `q` must not clear or stall the sampled-value history.
- The six-frame independent oracle uses reset samples `[0, 1, 0, 1, 0, 0]` and checks both prior-sample ages. BMC at the warm-up boundary must report a vacuous bounded pass; once the corresponding guard is valid, an unconstrained `b=0` can produce a frame-local failure that independently replays.

The expected evidence is limited to positive-edge, two-state, synchronous-reset, one- and two-sample `$past` forms in the approved Phase 0 profile.
