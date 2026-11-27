# Q3AFormal Specification Review Constitution

## Core Principles

### I. Scope Every Correctness Claim
A formal result applies only to the recorded elaborated model, assumptions, and published RTL/SVA profile. Review artifacts must distinguish source-level correctness from model-level proof evidence.

### II. Define Semantics Before Claiming Support
Supported syntax must have explicit parse, elaboration, lowering, and semantic behavior. Unresolved or unsupported semantics must be identified; silent approximations are unacceptable.

### III. Require Checkable Evidence
A conclusive result must have the corresponding validated witness or checked proof evidence. Bounded evidence, incomplete searches, and resource-limited runs must not be described as unbounded proof.

### IV. Preserve Reproducibility and Traceability
Findings must identify exact source sections and connect requirements to acceptance evidence. Analysis outputs must record the reviewed source revision and checksum.

### V. Keep Review Non-Destructive
This review may create artifacts only under `q3aformal`. The original Q3AFormal specification is read-only during analysis. Recommendations remain recommendations until the owner approves changes.

## Additional Constraints

- Respect the source specification's no-third-party runtime dependency requirement.
- Treat the source specification's open owner decisions as pending decisions, not as silently accepted facts.
- Distinguish a proven internal contradiction from a missing detail, an owner decision, or a feasibility risk.
- Do not claim that a checklist or AI review proves tool soundness.

## Review Workflow

1. Snapshot and hash the input specification.
2. Evaluate requirement quality using a domain-specific Spec Kit checklist.
3. Record actionable findings with severity, evidence location, impact, and proposed resolution.
4. Leave the input specification unchanged.

## Governance

The reviewed Q3AFormal specification is the authority for product intent. This review constitution governs only this analysis workspace and cannot override product requirements. Any product-specification edit requires a separately requested change.

**Version**: 1.0 | **Ratified**: 2026-11-15 | **Last Amended**: 2026-11-15
