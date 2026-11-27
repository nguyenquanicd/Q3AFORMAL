# Expected Results — sva_sequence_vectors.sv

**Vector ID:** SVV-001  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Provide source-level inputs for supported clock binding, concurrent properties, implication, constant delay, bounded consecutive repetition, and guarded history.

## Sample convention

All properties bind to the single positive-edge clock. At sample t, property operands use S[t] and I[t] before transition T computes S[t+1].

- p_overlapped: when a is true at sample t, b is required at sample t.
- p_nonoverlapped: when a is true at sample t, b is required at sample t+1.
- p_delay_zero: a and b are required at the same sequence sample; c is aligned with the end sample under overlapped implication.
- p_delay_one: b is sampled one clock edge after a.
- p_delay_two: b is sampled two clock edges after a.
- p_repeat_one and p_repeat_three exercise exact consecutive repetition counts 1 and 3.
- p_repeat_bounded permits consecutive match lengths from 1 through 3.
- p_past_one reads a from sample t-1 only when one prior sample exists.
- p_past_two reads a from sample t-2 only when two prior samples exist.

## Frame examples

For implication and delay:
- If a is true at sample 4, p_overlapped requires b at sample 4.
- Under the same antecedent, p_nonoverlapped requires b at sample 5.
- For p_delay_two, if a is true at sample 4, b is checked at sample 6.

For repetition:
- A three-match exact sequence requires a at three adjacent samples and ends on the third sample.
- The bounded 1:3 sequence can end after one, two, or three adjacent a matches; its following ##1 b is checked on the next sampled edge after each match end.

For history:
- At sample 0, no prior sample is valid.
- For $past(a), sample 0 is suppressed; sample 1 reads a from sample 0.
- For $past(a,2), samples 0 and 1 are suppressed; sample 2 reads a from sample 0.
- If RTL reset is asserted at sample 1, history age still advances; reset does not clear the sampled-value history.
## Expected model representation

- One clock binding is shared by the module properties.
- Assert, assume, and cover declarations remain distinct property kinds.
- Each constant delay/repetition bound is resolved at elaboration and stored in the property model.
- Generated history-valid state suppresses p_past_one until one sample has been captured and p_past_two until two samples have been captured. History is not cleared by RTL reset.
- The tautological assumption is consistent for every two-valued sample.

## Interpretation limit

This file defines source inputs and expected profile alignment. It is not proof output and does not establish parser conformance. Sequence-end corner cases must be reviewed against the normative language rules before the SVA matrix rows are marked conformant. Exact zero-count and zero-minimum repetition are separately rejected by the Phase 0 profile.




