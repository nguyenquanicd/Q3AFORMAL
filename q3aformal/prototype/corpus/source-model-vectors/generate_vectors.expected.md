# Expected Results — generate_vectors.sv

**Vector ID:** SM-006  
**Profile:** Q3A-P0 RTL profile, specification revision 0.9  
**Purpose:** Check constant generate selection, finite unrolling, stable generated names, and bit equations.

## Configuration A — WIDTH=4

The WIDTH == 4 generate-if branch is selected. g_width_four drives bit 0 with XOR; the generate-for loop creates bits 1, 2, and 3, each with XOR.

For a=4'b1010 and b=4'b0110, expected y=4'b1100.

The elaborated hierarchy contains g_width_four and g_bits[1], g_bits[2], g_bits[3]. g_other_width is absent from the elaborated model.

## Configuration B — WIDTH=3

The g_other_width branch is selected and drives bit 0 with AND. The generate-for loop creates bits 1 and 2 with XOR.

For a=3'b101 and b=3'b011, expected:
- bit 0 = 1 AND 1 = 1;
- bits 1 and 2 = corresponding XOR;
- y=3'b111.

The elaborated hierarchy contains g_other_width and g_bits[1], g_bits[2]. g_width_four and g_bits[0] are absent.

## Expected elaborated/T-IR properties

- WIDTH is resolved before generate expansion and is positive for this vector.
- Only the selected generate-if branch is elaborated.
- The loop index is constant in each unrolled body and preserves the source generate index in its stable name.
- No dynamic loop or runtime branch is created.
- Each output bit has exactly one driver.

## Review limits

This vector covers one true and one false generate-if configuration and representative finite unrolling. Zero-iteration, one-iteration, nested generate, invalid bound, and parameter override diagnostics remain required before the generate rows can be marked conformant.
