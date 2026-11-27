# RTL-017 Arithmetic Right-Shift Expected Results

**Profile:** Q3A-P0-R0.9.1, four-bit packed operands, compile-time distances 0–7.

The oracle exhausts all 16 values for each operand at all eight distances. `>>>` copies the left operand's sign bit into vacated high bits only when the left operand is signed. An unsigned left operand remains zero-filled even with the arithmetic-right-shift token. In contrast, `>>` is always a logical zero-fill shift. Distances at least the operand width produce all sign bits for a negative signed arithmetic shift, and zero otherwise.

The source properties describe the historical experimental behavior. The Phase 0 frontend rejects the source at `>>>`. The unit oracle compares SAT bit-blasting and witness replay for `>>` and `>>>` at four bits, with additional SAT boundary checks at widths 1, 8, 16, 32, and 64.
