# Expected T-IR Slice — `counter4_sequential`

**Profile:** Q3A-P0-R0.9.1  
**Top:** `counter4_sequential`

The restricted T016 sequential slice should emit one one-bit clock binding (`clk`), mark `count` as a four-bit state signal, and emit one four-bit next-state expression. The expression is a priority mux: synchronous reset selects zero; otherwise terminal count `4'hF` selects zero; otherwise `count + 4'd1` is selected. The initial RTL state remains unconstrained. This expected structure is not a proof result.
