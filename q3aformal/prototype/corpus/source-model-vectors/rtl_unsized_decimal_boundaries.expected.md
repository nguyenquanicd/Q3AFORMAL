# Unsized decimal literal boundaries

The reference values follow IEEE 1800-2023, clause 5.7.1. A positive signed decimal token uses at least 32 bits and keeps a sign bit above its magnitude. The minus sign is evaluated as a unary operator.

| Source value | Natural signed width | Expected behavior |
|---|---:|---|
| `2147483647` | 32 | Positive at the upper end of the signed 32-bit range |
| `2_147_483_648` | 33 | Positive and matches an exact-width 33-bit port |
| `4294967296` | 34 | Greater than `4294967295` |
| `4_294_967_297` | 34 | Assignment to 8 bits keeps the value 1 |
| `9_223_372_036_854_775_807` | 64 | Positive at the upper end of the supported range |
| `9223372036854775808` | 65 | Rejected with a source location before a formal result |

Assignment to the 40-bit destination preserves `2_147_483_648`. The property declaring `2147483648 < 0` is deliberately false and its counterexample must replay. The typed intermediate representation stores canonical decimal digits and preserves the token source location.
