# T020 Frame-by-Frame Replay Mutation Evidence

**Date:** 2026-11-20  
**Regression:** `prototype/tests/test_property_replay.ps1`

## Trace and oracle

The fixture models a one-bit environment input `a`, one-bit state `q`, and combinational output `y = a ^ q`, with next-state equation `q' = y`. The trace has two sampled frames and is checked against the assumption `a` and assertion `!y`. Its baseline counterexample passes independent replay.

The regression flips each data bit independently at both frames (six mutations total): `a[0]`, `q[0]`, and `y[0]`. Each mutated trace must be rejected by the replay implementation, exercising the assumption, combinational equation, next-state equation, and candidate assertion checks across frame boundaries.

The same test also mutates the replayed arithmetic result for every 3-bit/2-bit `+` and `-` operand pair under all four signedness combinations (256 corrupted traces). Replay must reject each trace against the independently evaluated combinational equation. For one-term overlapped and non-overlapped implication covers it flips the antecedent or consequent bit (four additional mutations). It also validates two-term `req ##1 ack |-> done` and `req ##1 ack |=> done` cover witnesses, then corrupts the antecedent start, delayed term, or consequent in each witness (six additional mutations). Separate negative traces verify that a consequent one cycle too late cannot satisfy `|->`, and a consequent at the antecedent endpoint cannot satisfy `|=>`. Replay rejects every broken witness while continuing to reject antecedent-only and vacuous traces.

## Result

```text
PASS: replay rejected every one-bit mutation of input, state, and combinational signal values in a two-frame counterexample.
PASS: replay validates bounded and induction witnesses and rejects equation, assumption, property, candidate-frame, and cover-goal mismatches.
```

`prototype/tests/test_property_replay.ps1` passed on 2026-11-20; exit code was 0.

## Scope and limits

This is bounded mutation evidence for one two-frame Boolean state model, 3-bit/2-bit addition and subtraction, and overlapped/non-overlapped implication covers with one- and two-term antecedents. It does not establish general replay coverage for all accepted RTL expressions, temporal automata, or full source-to-T-IR correctness. T020 remains open for broader profile-wide replay and proof-output integration.
