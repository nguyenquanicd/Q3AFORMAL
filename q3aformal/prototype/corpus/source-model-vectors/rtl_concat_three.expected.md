# Expected Results — Three-Member Packed Concatenation

**Vector ID:** SM-040  
**Matrix row:** RTL-015  
**Profile:** Q3A-P0-R0.9.1

The source expression `{a, b, c}` has operands with widths 2, 3, and 1 bits. It must lower to a six-bit concatenation whose ordered T-IR operands are `a`, `b`, `c`; the leftmost source operand occupies the most-significant bits.

For `a=2'b10`, `b=3'b101`, and `c=1'b1`, the independent expected value is:

```text
y = 2'b10 :: 3'b101 :: 1'b1 = 6'b101011 = 6'h2B
```

This vector adds a three-member mixed-width case to the existing two-member equal-width and mixed-width examples. It does not claim general IEEE sizing of context-dependent expressions inside concatenation operands.
