# Expected T016 Result — Sequential Child Output Bit-Selects

The direct generated top `sequential_child_output_bit_top` must lower four one-bit child output states under `g_lane[0..3].u_lane.__output_bit_actual.q`, each with exactly one next-state equation. The parent output `q` must have one complete four-bit concatenation equation whose lanes reference those distinct state signals.

The nested generated top `nested_sequential_child_output_bit_top` must lower four one-bit child output states under `g_lane[0..3].u_wrapper.__nested_output_bit_actual.q`, each with exactly one next-state equation. The parent output `q` must again be assembled by one complete four-bit equation. The properties must retain paths `g_lane[i].u_wrapper.u_lane.p_tracks_previous_input` and `g_lane[i].u_wrapper.u_lane.p_rejects_previous_input`.

For every lane in both tops, `p_tracks_previous_input` must return `BOUNDED_PASS` at frame 1. `p_rejects_previous_input` must return `BOUNDED_FAIL` with an independently replay-validated counterexample at frame 1. This checks the child transition, output state lane, parent bus assembly, guarded `$past`, and property aliasing through the wrapper.

## Sample-frame interpretation

The selected property uses pre-transition samples. `q[t]` is the child state visible at sample frame `t`; the `always_ff` update establishes `q[t+1] = d[t]`.

| Sample frame | Sampled `d[t]` | Visible `q[t]` | `$past(d)` | History guard | Property result |
|---:|---|---|---|---:|---|
| 0 | `D0` | unconstrained `Q0` | invalid | 0 | Not evaluated |
| 1 | `D1` | `D0` | `D0` | 1 | `D0 == q[1]`, true |
| 2 | `D2` | `D1` | `D1` | 1 | `D1 == q[2]`, true |

The inverse property fails at frame 1 with `D0 != D0`; its SAT witness must pass independent replay. This expected trace documents the distinction between values sampled at the clock event and the state produced by the subsequent nonblocking update.
