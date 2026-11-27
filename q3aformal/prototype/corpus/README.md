# Phase 0 Conformance Corpus

**Corpus profile:** Q3A-P0-R0.9.1  
**Specification:** ../../../Q3AFORMAL_SPECIFICATION.md, revision 0.10  
**Status:** Gate A prototype evidence is recorded for all 42 matrix rows. See the [source-to-model acceptance review](../../evidence/conformance/gate-a-source-model-review-2026-11-24.md) for the tested profile and limits.

Profile revision 0.9.1 records the owner-selected exact-width module-port rule; product specification revision 0.10 references this versioned matrix.

The conformance matrix is conformance-matrix.csv. `Planned` means implementation evidence is not yet recorded; `Partial` means some focused evidence exists while acceptance cases remain open; `Supported` requires all listed evidence and review. A status does not indicate whether an authored source example exists. Rows marked `Rejected` define inputs that must be diagnosed before proof.

## Phase 1 additions

The [Phase 1 addition matrix](phase1-conformance-additions.csv) records evidence for product manifest and preprocessing features, property attachment and inspection, finite timing, temporal assumptions, and rejection boundaries. It identifies the scope, regression suite, and positive, negative, boundary, and source-to-model evidence for each row. The [Phase 1 conformance plan](../../specs/003-phase1-block-mvp/plan.md#phase-1-source-and-property-conformance-additions) links to the qualification results.

## Phase 3 development matrix

The [Phase 3 development matrix](phase3-development-conformance.csv) records evidence and limits for the opt-in sampled-value profile. Release acceptance remains pending.

## Corpus areas

- source-model-vectors/: RTL inputs, expected elaboration/model behavior, and the T008 coverage map.
- sva-vectors/: supported assertion alignment, guarded $past, source-level sequence inputs, and rejection examples.
- reset-assumption-vectors/: reset transition and contradictory-assumption cases.
- reference-evaluator-spec.md: independent bounded evaluator contract and metamorphic relations.
- conformance-matrix.csv: supported/rejected profile inventory and evidence expectations.

Each vector is a specification artifact, not a passing test result. The source hashes, implemented parser/model outputs, and independent review status must be recorded when conformance evaluation is executed. No row may be marked Supported without that evidence.

## Implementation progress

- [T013 source manager build and smoke evidence](results/t013-source-manager.md)
- [T014 lexer/parser corpus evidence](results/t014-parser.md)
- [T015 elaborator implementation evidence](results/t015-elaborator-progress.md)
- [T016 RTL/SVA lowering progress](results/t016-lowering-progress.md)
- [T016 arithmetic, shift, and select bit-blasting evidence](results/t016-arithmetic-shift-bitblast-progress.md)

Focused RTL-to-SAT-to-replay regressions include `tests/test_bmc_arithmetic_shifts.ps1` and `tests/test_bmc_selects.ps1`; they establish only the listed expression slices.






