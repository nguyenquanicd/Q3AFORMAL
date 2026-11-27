$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$project = Join-Path $prototype 'pdr-temporal-assumptions.q3a'
$root = Join-Path ([IO.Path]::GetTempPath()) ('q3a-pdr-assumptions-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stderr = Join-Path $root 'stderr.log'

function Invoke-Pdr([string]$Project, [string]$Property, [string]$Status, [int]$Code,
                    [string[]]$Options = @()) {
    $proof = Join-Path $root "$Property-proof"
    $json = & $exe prove $Project --engine pdr --property $Property --evidence-dir $proof @Options 2> $stderr
    $actual = $LASTEXITCODE
    $result = $json | ConvertFrom-Json
    if ($actual -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Property to produce $Status ($Code). Actual: $json. $(Get-Content $stderr -Raw)"
    }
    $result
}

try {
    $ranges = Join-Path $prototype 'sva-induction-variable-delay-assumptions.q3a'
    $guarded = Join-Path $prototype 'sva-induction-delayed-guarded-assumption.q3a'
    $proofCases = @(
        @{ Manifest = $project; Property = 'p_local'; Status = 'PROVEN' },
        @{ Manifest = $project; Property = 'c_excluded'; Status = 'UNREACHABLE' },
        @{ Manifest = $ranges; Property = 'p_sequence_target'; Status = 'PROVEN' },
        @{ Manifest = $ranges; Property = 'p_implication_target'; Status = 'PROVEN' }
    )
    $proofs = foreach ($case in $proofCases) {
        $null = Invoke-Pdr $case.Manifest $case.Property $case.Status 0
        $path = Join-Path $root "$($case.Property)-proof"
        $verified = @(& $exe verify-pdr $case.Manifest --property $case.Property --evidence-dir $path)
        if ($LASTEXITCODE -ne 0 -or $verified -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw "Certificate failed to reopen for $($case.Property)."
        }
        $path
    }
    & (Join-Path $PSScriptRoot 'test_drat_independent_full_scan.ps1') -PdrEvidence $proofs

    $witnesses = @(
        @{ Manifest = $project; Property = 'p_too_strong'; Status = 'FAIL'; Depth = 1 },
        @{ Manifest = $project; Property = 'c_allowed'; Status = 'COVERED'; Depth = 1 },
        @{ Manifest = $ranges; Property = 'p_false_target_under_delay_assumptions'; Status = 'FAIL'; Depth = 2 }
    )
    foreach ($case in $witnesses) {
        $bundle = Join-Path $root "$($case.Property)-bundle"
        $result = Invoke-Pdr $case.Manifest $case.Property $case.Status 0 @('--max-depth', [string]$case.Depth, '--bundle-dir', $bundle)
        $configuration = $result.pdr_configuration
        if ($null -ne $result.certificate -or $configuration.maximum_depth -ne $case.Depth -or
            $null -eq $result.elapsed_ms -or !$configuration.assumptions.Count) {
            throw "Unexpected run configuration or certificate publication for $($case.Property)."
        }
        if ($case.Manifest -ceq $project -and ($configuration.assumptions -join ',') -cne 'env_next') {
            throw "Incorrect assumption identity for $($case.Property)."
        }
        $log = Get-Content -LiteralPath $stderr -Raw
        $checked = @(& $exe --verify-bundle $bundle)
        if ($log -notmatch "Q3A_PDR_DEPTH $($case.Depth)\b" -or
            $LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Witness or depth check failed for $($case.Property): $log."
        }
        "PASS: $($case.Property) reported $($case.Status) at depth $($case.Depth) with independently replayed assumptions."
    }

    $guardedBundle = Join-Path $root 'guarded-prefix-bundle'
    $null = Invoke-Pdr $guarded 'p_target' 'FAIL' 0 @('--max-depth', '2', '--bundle-dir', $guardedBundle)
    $log = Get-Content -LiteralPath $stderr -Raw
    $checked = @(& $exe --verify-bundle $guardedBundle)
    if ($log -notmatch 'Q3A_PDR_DEPTH 0\b' -or $LASTEXITCODE -ne 0 -or
        $checked -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
        throw 'A guarded assumption must leave the incomplete initial prefix available.'
    }
    'PASS: guarded assumptions allow an initial prefix before the first complete window.'

    Copy-Item (Join-Path $prototype 'corpus/source-model-vectors/pdr_temporal_assumptions.sv') (Join-Path $root 'fixture.sv')
    $contradiction = Join-Path $root 'contradiction.q3a'
    @('Q3AFORMAL_PROJECT 1', 'top pdr_temporal_contradiction', 'source "fixture.sv"') |
        Set-Content $contradiction
    foreach ($property in 'p_false', 'p_true') {
        $null = Invoke-Pdr $contradiction $property 'INCONSISTENT_MODEL_OR_ASSUMPTIONS' 1
        if ((Get-Content -LiteralPath $stderr -Raw) -notmatch 'Q3A_PDR_DEPTH 1\b' -or
            (Test-Path -LiteralPath (Join-Path $root "$property-proof"))) {
            throw 'Contradiction at the first complete assumption window created a final result artifact.'
        }
    }
    $excessive = Join-Path $root 'excessive.q3a'
    @('Q3AFORMAL_PROJECT 1', 'top pdr_excessive_assumption', 'source "fixture.sv"') |
        Set-Content $excessive
    $result = Invoke-Pdr $excessive 'p_true' 'UNSUPPORTED' 2
    if ($result.diagnostics[0].location.line -lt 1 -or
        $result.diagnostics[0].message -notmatch 'final sample offset of at most 128: env_excessive') {
        throw 'Expected a source-located excessive assumption horizon.'
    }
    'PASS: PDR compiled finite temporal assumptions, checked contradiction before publication, and rejected excessive horizons.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-pdr-assumptions-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
