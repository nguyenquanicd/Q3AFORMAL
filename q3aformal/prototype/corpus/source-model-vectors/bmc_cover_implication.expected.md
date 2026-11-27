# Expected Results — `bmc_cover_implication.sv`

**Vector ID:** SM-051  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** SVA-004

The source defines scalar overlapped cover (`req |-> ack`), scalar non-overlapped cover (`req |=> ack`), and a sequence antecedent cover (`req ##1 data_valid |=> ack`). With sufficient bound, each query must return `COVERED`, `WITNESS_FOUND`, and `REPLAY VALIDATED`. A non-overlapped query at an insufficient bound must remain `UNKNOWN` with `NOT_FOUND_WITHIN_BOUND` and an incomplete-bound scope; it must not be reported as unreachable.

`test_sequence_bmc_bitblast.ps1` compares scalar, sequence, and implication-cover CNF against independent trace evaluation over the authored finite assignment sets. The cover semantics are bounded reachability checks; this vector does not define IEEE vacuous-success coverage counters.

An `ack[*1:2]` consequent has an eligible one-sample match even when the second sample is outside the trace. The overlapped form covers at frame 0 and the non-overlapped form at frame 1, both with an incomplete boundary. With `ack[*2:3]` and only one consequent sample available, the query remains `UNKNOWN`.

The standalone `ack[*1:256]` cover must complete within 256 transitions with a replay-validated witness and within the encoding-size limits in `test_bmc_cover_implication.ps1`. The chained `ack[*1:16] ##1 req[*1:16] ##1 data_valid[*1:16]` cover must complete within 300 transitions with a replay-validated witness. Independent finite-trace oracles also compare converging paths for a three-term cover and a ranged assertion antecedent.
