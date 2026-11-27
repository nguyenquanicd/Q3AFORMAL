$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$root = Join-Path ([IO.Path]::GetTempPath()) ('q3a-vacuity-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stderr = Join-Path $root 'stderr.txt'

function Invoke-Prove([int]$Code, [string]$Status, [string[]]$Options) {
    $json = & $exe prove @Options 2> $stderr
    $actual = $LASTEXITCODE
    $result = $json | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Status ($Code), got $json. $(Get-Content $stderr -Raw)"
    }
    $result.properties[0]
}

try {
    $past = Join-Path $prototype 'bmc-past.q3a'
    foreach ($case in @(
        @{ Depth = 0; Code = 1; Status = 'BOUNDED_PASS'; Activity = 'NOT_REACHED'; Vacuity = 'INCOMPLETE' },
        @{ Depth = 1; Code = 0; Status = 'BOUNDED_FAIL'; Activity = 'REACHED'; Vacuity = 'NOT_DETECTED_WITHIN_SCOPE' }
    )) {
        $property = Invoke-Prove $case.Code $case.Status @($past, '--engine', 'bmc', '--property',
            'p_past_a', '--frames', [string]$case.Depth)
        $scope = $property.vacuity
        if ($scope.scope -cne 'BOUNDED' -or $scope.bound -ne $case.Depth -or
            $scope.feasibility -cne 'SAT' -or $scope.activation -cne $case.Activity -or
            $scope.status -cne $case.Vacuity) {
            throw "Incorrect vacuity scope at history depth $($case.Depth)."
        }
    }
    $fixed = Join-Path $prototype 'pdr-fixed-sequence.q3a'
    $pending = Invoke-Prove 1 'BOUNDED_PASS' @($fixed, '--engine', 'bmc', '--property',
        'p_wrong_pipeline', '--frames', '1')
    if ($pending.vacuity.boundary_obligations -cne 'INCOMPLETE' -or
        $pending.vacuity.status -cne 'INCOMPLETE') {
        throw 'A result before the temporal window ends must preserve that boundary.'
    }
    $cover = Invoke-Prove 0 'COVERED' @($fixed, '--engine', 'bmc', '--property',
        'c_reachable', '--frames', '2')
    if ($cover.PSObject.Properties.Name -ccontains 'vacuity') {
        throw 'Cover reported assertion-specific vacuity.'
    }

    $proof = Join-Path $root 'proof'
    $knownBundle = Join-Path $root 'feasible-bundle'
    $project = Join-Path $prototype 'counter4.q3a'
    $proved = Invoke-Prove 0 'PROVEN' @($project, '--engine', 'induction', '--property',
        'p_wraps_to_zero', '--k', '1', '--output-prefix', $proof, '--bundle-dir', $knownBundle)
    if ($proved.vacuity.scope -cne 'BOUNDED' -or $proved.vacuity.bound -ne 2 -or
        $proved.vacuity.feasibility -cne 'SAT') {
        throw 'Induction did not report the feasibility prefix separately from the proof.'
    }
    $reopened = @(& $exe --verify-bundle $knownBundle 2> $stderr)
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_INDUCTION_FEASIBILITY VERIFIED bound=2' -or
        $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'A consistent proof did not reopen with the regenerated feasibility check.'
    }
    $conflict = Join-Path $prototype 'bmc-conflict.q3a'
    $unused = Join-Path $root 'no-proof'
    $bundle = Join-Path $root 'conflict-bundle'
    $rejected = Invoke-Prove 1 'INCONSISTENT_MODEL_OR_ASSUMPTIONS' @($conflict, '--engine', 'induction',
        '--property', 'p_assert_a', '--output-prefix', $unused, '--bundle-dir', $bundle)
    if ($rejected.vacuity.feasibility -cne 'UNSAT' -or $rejected.vacuity.activation -cne 'NOT_CHECKED' -or
        $rejected.vacuity.status -cne 'INCOMPLETE' -or !(Test-Path -LiteralPath $bundle -PathType Container) -or
        @(Get-ChildItem -LiteralPath $root -Filter 'no-proof*').Count) {
        throw 'Induction issued proof evidence or claimed activation under conflicting assumptions.'
    }

    $manifest = Get-Content -LiteralPath (Join-Path $bundle 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.queries.Count -ne 1 -or $manifest.queries[0].kind -cne 'model-feasibility' -or
        $manifest.queries[0].status -cne 'UNSAT') {
        throw 'A contradictory run recorded a query other than environment feasibility.'
    }
    $reopened = @(& $exe --verify-bundle $bundle --require-source-model 2> $stderr)
    $bound = $rejected.vacuity.bound
    if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
        $reopened -cnotcontains "Q3A_BUNDLE_BMC_QUERY REVALIDATED status=INCONSISTENT_MODEL_OR_ASSUMPTIONS bound=$bound") {
        throw 'The contradiction archive did not revalidate as a feasibility query.'
    }

    Copy-Item (Join-Path $prototype 'corpus/source-model-vectors/pdr_temporal_assumptions.sv') (Join-Path $root 'fixture.sv')
    $temporal = Join-Path $root 'temporal.q3a'
    @('Q3AFORMAL_PROJECT 1', 'top pdr_temporal_contradiction', 'source "fixture.sv"') |
        Set-Content -LiteralPath $temporal
    $rejected = Invoke-Prove 1 'INCONSISTENT_MODEL_OR_ASSUMPTIONS' @($temporal, '--engine',
        'induction', '--property', 'p_true', '--output-prefix', $unused)
    if ($rejected.vacuity.feasibility -cne 'UNSAT' -or $rejected.vacuity.bound -ne 1 -or
        @(Get-ChildItem -LiteralPath $root -Filter 'no-proof*').Count) {
        throw 'The first complete temporal assumption window did not prevent a proof.'
    }
    $oldBundle = Join-Path (Split-Path -Parent $prototype) 'evidence/known-fail/induction-contradiction-legacy-2026-11-25/bundle'
    $reopened = @(& $exe --verify-bundle $oldBundle 2> $stderr)
    if ($LASTEXITCODE -ne 1 -or $reopened -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content -LiteralPath $stderr -Raw) -notmatch 'induction proof has an inconsistent model or assumptions') {
        throw 'An archived vacuous proof reopened as a valid proof.'
    }

    $certificate = Join-Path $root 'pdr-certificate'
    $pdr = Invoke-Prove 0 'PROVEN' @($fixed, '--engine', 'pdr', '--property', 'p_pipeline',
        '--evidence-dir', $certificate)
    if ($pdr.vacuity.scope -cne 'UNAVAILABLE' -or $pdr.vacuity.status -cne 'INCOMPLETE' -or
        $pdr.vacuity.activation -cne 'NOT_CHECKED' -or $pdr.vacuity.PSObject.Properties.Name -ccontains 'bound') {
        throw 'A PDR safety proof claimed activation without checking it.'
    }
    $failure = Invoke-Prove 0 'FAIL' @($fixed, '--engine', 'pdr', '--property', 'p_wrong_pipeline',
        '--evidence-dir', (Join-Path $root 'unused-pdr'))
    if ($failure.vacuity.scope -cne 'BOUNDED' -or $failure.vacuity.bound -ne 2 -or
        $failure.vacuity.activation -cne 'REACHED') {
        throw 'A replayed PDR failure did not retain its bounded activation evidence.'
    }
    'PASS: bounded activation, inactive warmup, pending windows, separate cover semantics, and unavailable PDR activation.'
    'PASS: induction rejects same-sample and delayed assumption contradictions; the verifier rejects a contradictory legacy bundle.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-vacuity-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
