# Expression-Valued Child Input Expected Behavior

**Vector ID:** SM-020  
**Profile:** Q3A-P0-R0.9.1, specification revision 0.10

The child input `a` is connected to the parent expression `lhs ^ rhs`; child input `b` is connected to `rhs`; the child output `equal` drives `same`. Both child input expressions have the exact four-bit formal width. The expected flattened relation is:

```text
same = ((lhs ^ rhs) == rhs)
```

The test checks the flattened expression tree and representative values. Output actuals in this T016 slice must still be a single top-level signal identifier. This vector does not validate all IEEE 1800 expression-sizing or signedness rules. Child-local combinational nets are covered separately by SM-021.
