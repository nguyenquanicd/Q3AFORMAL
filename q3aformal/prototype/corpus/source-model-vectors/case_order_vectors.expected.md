# Expected Results — case_order_vectors.sv

**Vector ID:** SM-011  
**Profile:** Q3A-P0-R0.9.1  
**Purpose:** Check exact case matching, default selection, and source-order behavior for duplicate matching items.

| select | Expected result | Reason |
|---|---|---|
| 00 | 00 | First exact item matches |
| 01 | 01 | First matching item in source order wins; the later duplicate is not selected |
| 10 | 11 | No explicit item matches; default is selected |
| 11 | 11 | No explicit item matches; default is selected |

The process assigns result on all paths and introduces no latch. The duplicate item is intentional profile input; preserve source order in elaboration.
