# T017 RTL-011–RTL-014 Mixed-Width Conformance Evidence

**Date:** 2026-11-20  
**Vector:** SM-050, `bmc_mixed_width.sv`  
**Regressions:** `test_sat_relational_bitblast.ps1`, `test_property_replay.ps1`, `test_bmc_mixed_width.ps1`, and `test_sat_arithmetic_shift_bitblast.ps1`

## Evidence

All four regressions passed on 2026-11-20.

- **RTL-011 arithmetic:** the bit-blaster checks mixed-width addition and subtraction, carry/borrow truncation, sign/zero extension, and all signedness combinations for the tested three-bit/two-bit values. The independent replay oracle checks operation results. The source vector checks signed mixed-width addition against an explicit sign-extended reference.
- **RTL-012 bitwise:** SAT and replay cover mixed-width bitwise operators across the tested signedness combinations. The source vector checks unsigned XOR against an explicitly zero-extended operand.
- **RTL-013 comparison:** SAT/replay cover equality and all listed relational operators over the tested widths and signedness combinations. Source properties check unsigned relational/equality extension and signed relational extension.
- **RTL-014 conditional:** SAT/replay cover both conditional branches across the tested signedness combinations. The source property checks a signed narrow branch against its explicit sign extension.

These rows are **Supported for the tested bounded three-bit/two-bit expression profile**. The source-level checks are nonvacuous, and the replay regression independently evaluates the sampled values and branch choices.

## Limits

This evidence does not establish arbitrary operand widths, all IEEE 1800 context-determined sizing, four-state equality, multiplication/division/modulo, every source-level mixed-signedness combination, or wide carry/truncation boundaries. The status applies to the tested expression subsets only; T016/T017 remain open for broader conformance.
