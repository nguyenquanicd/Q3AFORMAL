# Expected Results — `rtl_unary_conformance.sv`

**Vector ID:** SM-049  
**Profile:** Q3A-P0-R0.9.1  
**Matrix row:** RTL-010

For each four-bit unsigned input `u`, `+u` returns `u`, `-u` returns `(-u) mod 16`, `~u` returns the four-bit complement, and `!u` returns one only when `u` is zero. The four results have widths 4, 4, 4, and 1, respectively.

`test_unary_conformance.ps1` checks T-IR operator kinds, operand/result widths and source lines; evaluates all 16 input values independently for every operator (64 comparisons); requires four nonvacuous bounded passes; and checks a replay-validated counterexample for a deliberately false unary-plus property.

The vector covers only four-bit unsigned operands. Signed unary operations, wider widths, and full source-to-model boundary conformance remain open.
