# Expected Elaboration — Port Expression Widths

**Profile:** Q3A-P0-R0.9.1  
**Top:** `port_expression_top`

The `u_concat` actual is a concatenation of two two-bit part-selects and resolves to four bits. The unbased unsized fill literal `'0` is context-sized to the four-bit formal port. The explicitly sized `4'hA` actual is four bits. All three direct connections therefore meet the exact-width rule. This expected result covers width inference only; it does not claim expression lowering or simulation.
