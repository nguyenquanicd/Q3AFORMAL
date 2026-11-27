$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$project = Join-Path $prototype 'pdr-fixed-sequence.q3a'
$root = Join-Path ([IO.Path]::GetTempPath()) ('q3a-pdr-sequence-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$stderr = Join-Path $root 'stderr.txt'

function Test-Outcome([string]$Property, [string]$Status, [int]$Code, [string[]]$Options = @()) {
    $certificate = Join-Path $root "$Property-proof"
    $output = & $exe prove $project --engine pdr --property $Property --evidence-dir $certificate @Options 2> $stderr
    $exitCode = $LASTEXITCODE
    $result = $output | ConvertFrom-Json
    if ($exitCode -ne $Code -or $result.exit_code -ne $Code -or $result.status -cne $Status) {
        throw "Expected $Property to produce $Status ($Code). Actual: $output. $(Get-Content $stderr -Raw)"
    }
    return $result
}

function Test-Proofs([string[]]$Properties) {
    foreach ($property in $Properties) {
        $status = if ($property.StartsWith('c_')) { 'UNREACHABLE' } else { 'PROVEN' }
        $null = Test-Outcome $property $status 0
        $path = Join-Path $root "$property-proof"
        $checked = @(& $exe verify-pdr $project --property $property --evidence-dir $path)
        if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_PDR_CERTIFICATE VERIFIED') {
            throw "Could not reopen the monitor certificate for $property."
        }
        $path
    }
}

function Test-Witnesses([hashtable[]]$Cases) {
    foreach ($case in $Cases) {
        $null = Test-Outcome $case.Property 'UNKNOWN' 1 @('--max-depth', [string]($case.Sample - 1))
        $bundle = Join-Path $root "$($case.Property)-bundle"
        $null = Test-Outcome $case.Property $case.Status 0 @('--max-depth', [string]$case.Sample, '--bundle-dir', $bundle)
        $log = Get-Content -LiteralPath $stderr -Raw
        if ($log -notmatch "Q3A_PDR_DEPTH $($case.Sample)\b" -or $log -notmatch 'Q3A_BMC_REPLAY VALIDATED') {
            throw "Expected replayed completion at sample $($case.Sample) for $($case.Property)."
        }
        $reopened = @(& $exe --verify-bundle $bundle)
        if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Could not reopen the source witness for $($case.Property)."
        }
        "PASS: $($case.Property) returned $($case.Status) at sample $($case.Sample); the source witness reopened."
    }
}

try {
    $proofs = @(Test-Proofs @('p_pipeline', 'p_repeat', 'p_consequent_delay',
        'p_guarded_pipeline', 'p_standalone', 'c_unreachable', 'c_unreachable_implication'))
    Test-Witnesses @(
        @{ Property = 'p_wrong_pipeline'; Status = 'FAIL'; Sample = 2 },
        @{ Property = 'p_wrong_guarded'; Status = 'FAIL'; Sample = 3 },
        @{ Property = 'p_consequent_guard'; Status = 'FAIL'; Sample = 3 },
        @{ Property = 'p_standalone_fail'; Status = 'FAIL'; Sample = 2 },
        @{ Property = 'c_reachable'; Status = 'COVERED'; Sample = 2 },
        @{ Property = 'c_guarded_hit'; Status = 'COVERED'; Sample = 2 }
    )
    $rejected = Test-Outcome 'p_excessive_horizon' 'UNSUPPORTED' 2
    if ($rejected.diagnostics[0].location.line -lt 1 -or
        $rejected.diagnostics[0].message -notmatch 'final sample offset of at most 128') {
        throw 'The rejection did not identify the unsupported source sequence.'
    }
    'PASS: fixed sequences, repetitions, both history guards, certificate and witness reopening, and rejection of excessive horizons.'

    $project = Join-Path $prototype 'pdr-range-sequence.q3a'
    $proofs += @(Test-Proofs @('p_either_endpoint', 'p_late_endpoint',
        'p_repeated_antecedent', 'c_unreachable_range'))
    Test-Witnesses @(
        @{ Property = 'p_no_consequent_match'; Status = 'FAIL'; Sample = 2 },
        @{ Property = 'p_late_trigger'; Status = 'FAIL'; Sample = 2 },
        @{ Property = 'p_overlapping_matches'; Status = 'FAIL'; Sample = 3 },
        @{ Property = 'p_standalone_range'; Status = 'FAIL'; Sample = 2 },
        @{ Property = 'p_end_guard'; Status = 'FAIL'; Sample = 4 },
        @{ Property = 'c_short_hit'; Status = 'COVERED'; Sample = 2 },
        @{ Property = 'c_repeated_hit'; Status = 'COVERED'; Sample = 2 }
    )
    & (Join-Path $PSScriptRoot 'test_drat_independent_full_scan.ps1') -PdrEvidence $proofs
    'PASS: finite delays and repetitions, merged paths, earliest cover hits, and full-window assertion failures.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -eq $root -and (Split-Path -Leaf $root) -like 'q3a-pdr-sequence-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
