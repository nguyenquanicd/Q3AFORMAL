# Reset and Assumption Vectors

These expected cases use the Phase 0 convention: S[t] is sampled before edge t; synchronous reset sampled at edge t determines S[t+1]. Reset is not an initial-state constraint.

| ID | Initial state/input sequence | Expected model behavior | Expected diagnostic/status |
|---|---|---|---|
| RST-01 reset-held | S[0].count arbitrary; rst[0]=1, rst[1]=1 | count in S[1] and S[2] is the reset value | Valid transition sequence |
| RST-02 release | rst[0]=1 then rst[1]=0 | First edge resets; next edge follows normal transition logic | Valid transition sequence |
| RST-03 reassert | rst[0]=1, rst[1]=0, rst[2]=1 | State follows reset assignment again at S[3] | Valid transition sequence |
| RST-04 no startup assumption | No constraint on rst[0] | Both reset and non-reset transitions are legal from unconstrained S[0] | Must not invent startup reset |
| RST-05 unreset register | State bit has no reset assignment and no initialization | Both values are allowed in S[0] | Must not set a default constant |
| RST-06 explicit startup assumption | Assume rst[0]=1 for the selected startup frame | Initial environment is constrained only by the recorded assumption; transition still applies reset at the edge | Assumption appears in manifest |
| RST-07 contradictory initial assumptions | Initial assumptions require rst=1 and rst=0 simultaneously | No legal initial state exists | Report contradiction; do not claim functional coverage |
| RST-08 frame-local contradiction | At a sampled frame, assumptions require input x=0 and x=1 | No legal input assignment at that frame | Report contradiction and frame/scope |
| RST-09 contradiction not established | A bounded run finds no satisfying activation but completeness is unavailable | Do not conclude global vacuity/unreachability | Vacuity metadata is INCOMPLETE |
| RST-10 reset type mismatch | Source uses asynchronous reset event control | No transition model is generated | UNSUPPORTED before proof |

## Review notes

- The reset inputs are allowed to remain asserted and to reassert at any later edge.
- Synchronous reset does not constrain S[0] before the first edge.
- A reset assumption is part of every relevant proof obligation and is serialized with the result.
- Reset-related SVA properties use explicit sampled predicates because disable iff is outside the Phase 0 profile.
