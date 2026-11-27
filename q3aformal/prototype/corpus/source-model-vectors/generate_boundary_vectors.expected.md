# Expected Results — generate_boundary_vectors.sv

**Vector IDs:** SM-012, SM-013  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check zero/one/multiple generate-for iterations and nested static generate-if branch selection.

## Generate-for configurations

| COUNT | Expected is_one | Elaborated generated scopes |
|---:|---:|---|
| 0 | 0 | No g_items scope |
| 1 | 1 | g_items[0], with ITEM_INDEX=0 |
| 3 | 0 | g_items[0], g_items[1], g_items[2], with matching constant indices |

The generate loop is resolved at elaboration. It does not create runtime iterations or state.

## Nested generate-if configurations

| WIDTH | ENABLE | Expected relation and example | Selected scopes |
|---:|---:|---|---|
| 4 | 1 | y=a^b; with a=4'hA,b=4'h5, y=4'hF | g_enabled.g_width_four |
| 3 | 1 | y=a&b; with a=3'b101,b=3'b011, y=3'b001 | g_enabled.g_other_width |
| 4 | 0 | y='0; expected y=4'h0 | g_disabled |

Only the selected generate branches exist in the elaborated hierarchy. The unselected nested branches are absent from E-IR/T-IR and carry no runtime logic.

These vectors cover zero, one, and multiple finite loop instances. A statically non-terminating loop or a bound outside the profile's supported elaboration limit must be rejected with a source-located diagnostic; it is not an accepted configuration.
