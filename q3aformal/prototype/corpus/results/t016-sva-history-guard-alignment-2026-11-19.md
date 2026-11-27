# T-IR 0.4 SVA History-Guard Alignment

## Finding

T-IR 0.3 stored one history-valid guard for the whole property. Bounded assertion, cover, and assumption encoding applied that guard at the antecedent start, even when `$past` appeared only in a delayed consequent term. That could suppress a real bounded failure or cover hit. The same property-wide guard also could not describe a history reference whose sequence term was delayed enough that its `$past` value was already valid at the term's sample.

## Change

T-IR 0.4 preserves the legacy property-wide guard for audit and compatibility, and adds separate antecedent and consequent guard delay/signal fields. The lowerer computes each sequence's required warm-up from the earliest sample offset of each term that contains `$past`. For a history depth `d` first used at sequence offset `o`, that term requires `max(d - o, 0)` valid samples at sequence start. This handles nested `$past`, fixed delays, bounded repetitions, and the finite delay-range encoding used by the current subset.

The bounded-model-checking assertion, cover, and assumption encoder now applies antecedent validity at antecedent start and consequent validity at consequent start. The k-induction encoder and independent replay use the same timing. Generated history-state initialization remains unchanged. Bundle reopening accepts both T-IR 0.3 (legacy property-wide semantics) and T-IR 0.4 (split operand guards).

## Regression evidence

`prototype/tests/test_sva_delayed_past_implication.ps1` exercises:

- Assertions and covers with `$past` in delayed antecedent and consequent terms. They produce frame-1 results with validated witnesses even though history is invalid at property start.
- Assertions with `$past` at an immediate antecedent or consequent sample, and a cover with immediate consequent history. They remain inactive before history is available, then use the correct operand guard and replay at frame 1.
- T-IR metadata showing independent operand guards and reduced warm-up delay for a history use at sequence offset one.

The following regressions passed after rebuilding: `test_sva_history_equations.ps1`, `test_sva_sequence_alignment_oracle.ps1`, `test_sva_delayed_past_implication.ps1`, `test_bmc_property_queries.ps1`, `test_bmc_cover_implication.ps1`, `test_inductive_sva_implication.ps1`, `test_result_bundle.ps1`, `test_bundle_reopen.ps1`, `test_child_property_lowering.ps1`, and `test_transition_cnf_frames.ps1`. The induction regression now proves `a |=> $past(a)` and replays a failure under a delayed guarded-history assumption instead of expecting those cases to be rejected. The fresh build ID is `8179c6f3e88ed72936b761c694e84cddd9beea323bfa99fd2aab940cb1d19e7d`.

## Remaining boundary

This fixes guard placement for the accepted linear, finite SVA subset. It does not implement all IEEE 1800 property sampling, multi-clock semantics, unbounded sequence operators, or certify full RTL-to-T-IR correctness. T-IR 0.4 improves representation and tested semantics but does not close T016, T017, T018, or T020.
