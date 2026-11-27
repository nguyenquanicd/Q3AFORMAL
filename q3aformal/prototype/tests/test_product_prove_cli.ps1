param([string]$ExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$prototype = Split-Path -Parent $PSScriptRoot
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$scratch = New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-prove-cli-' + [Guid]::NewGuid()))
$stderr = Join-Path $scratch.FullName 'stderr.txt'

function Check-Prove($Name, $ExpectedCode, $ExpectedStatus, $ExpectedProperty, $Arguments, $ExpectedLimit,
    $ExpectedTimeout, $ExpectedDiagnostic) {
    $stdout = @(& $exe prove @Arguments 2> $stderr)
    $actualCode = $LASTEXITCODE
    if ($stdout.Count -ne 1) {
        throw "$Name expected exactly one JSON line on standard output. Got $($stdout.Count)."
    }
    $payload = $stdout[0] | ConvertFrom-Json
    if ($actualCode -ne $ExpectedCode -or $payload.exit_code -ne $ExpectedCode -or
        $payload.schema_version -ne 1 -or $payload.status -cne $ExpectedStatus) {
        throw "$Name expected $ExpectedCode / $ExpectedStatus. Got $actualCode / $($stdout[0]). $(Get-Content $stderr -Raw)"
    }
    if ($ExpectedLimit) {
        if ($payload.resource_limit -cne $ExpectedLimit) {
            throw "$Name is missing the resource classification. $($stdout[0])"
        }
    } elseif ($payload.PSObject.Properties.Name -contains 'resource_limit') {
        throw "$Name must not report a resource limit. $($stdout[0])"
    }
    if ($ExpectedTimeout) {
        if ($payload.timeout_ms -ne $ExpectedTimeout -or $null -eq $payload.elapsed_ms -or
            ($ExpectedStatus -ceq 'TIMEOUT' -and
                ($payload.elapsed_ms -lt $ExpectedTimeout -or
                 $payload.timeout_stage -cnotin @('source_loading','elaboration','bounded_query','witness_replay',
                    'induction_obligations','pdr_search','pdr_certificate')))) {
            throw "$Name has an incorrect deadline report. $($stdout[0])"
        }
    } elseif ($payload.PSObject.Properties.Name -contains 'timeout_ms') {
        throw "$Name must not report a deadline. $($stdout[0])"
    }
    if ($ExpectedDiagnostic) {
        $diagnostic = $payload.diagnostics[0]
        if ($payload.diagnostics.Count -ne 1 -or $diagnostic.code -cne $ExpectedDiagnostic -or
            $diagnostic.severity -cne 'error' -or !$diagnostic.message -or
            !$diagnostic.location.file -or $diagnostic.location.line -lt 1 -or
            $diagnostic.location.column -lt 1) {
            throw "$Name did not supply the expected source diagnostic. $($stdout[0])"
        }
    } elseif ($payload.PSObject.Properties.Name -contains 'diagnostics') {
        throw "$Name must not report a source diagnostic. $($stdout[0])"
    }
    if ($ExpectedStatus -ceq 'TIMEOUT' -and $payload.timeout_stage -ceq 'source_loading') {
        if ($payload.PSObject.Properties.Name -ccontains 'source_set_sha256' -or
            $payload.completed_work.Count -ne 0 -or $payload.resolved_configuration) {
            throw "$Name claimed completed source loading after an early deadline."
        }
        if ($Arguments -cnotcontains '--engine') {
            if ($payload.engine) { throw "$Name identified a manifest-selected engine before loading the manifest." }
            $ExpectedProperty = $null
        }
    }
    if ($ExpectedProperty) {
        if ($payload.properties.Count -ne 1 -or $payload.properties[0].name -cne $ExpectedProperty -or
            $payload.properties[0].status -cne $ExpectedStatus) {
            throw "$Name has an incorrect per-property result. $($stdout[0])"
        }
    } elseif ($payload.properties.Count -ne 0) {
        throw "$Name must not record a property result for a request with no property."
    }
    Write-Output "PASS $Name $actualCode $ExpectedStatus"
}

try {
    Push-Location -LiteralPath $scratch.FullName
    $help = @(& $exe --help 2> $stderr)
    if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $stderr).Length -ne 0) {
        throw 'Product help must write to standard output and return zero.'
    }
    $usage = $help -join [char]10
    foreach ($command in 'properties PROJECT', 'prove PROJECT', 'prove-batch PROJECT', 'verify-pdr PROJECT',
        '--verify-bundle DIR_OR_INTERRUPTION_RECORD', 'debug BUNDLE', 'trace import-vcd FILE', 'trace view-vcd FILE',
        'trace window FILE') {
        if (!$usage.Contains($command)) { throw "Product help omitted $command." }
    }
    $version = @(& $exe --version 2> $stderr)
    if ($LASTEXITCODE -ne 0 -or $version.Count -ne 1 -or (Get-Item -LiteralPath $stderr).Length -ne 0) {
        throw 'Product version must emit exactly one JSON line and return zero.'
    }
    $identity = $version[0] | ConvertFrom-Json
    if ($identity.schema_version -ne 1 -or $identity.tool -cne 'q3aformal-sourcecheck' -or
        $identity.build_id -cnotmatch '^[0-9a-f]{64}$' -or !$identity.compiler -or
        $identity.build_configuration -notmatch '(^| )-std=c\+\+17( |$)' -or
        $identity.checker_id -cne 'q3a-drat-checker-0.2' -or $identity.proof_artifact_schema -ne 2) {
        throw 'Product version lost its build or proof checker identity.'
    }
    foreach ($flag in '--help','--version') {
        $unexpected = @(& $exe $flag unexpected 2> $stderr)
        if ($LASTEXITCODE -ne 2 -or $unexpected.Count -ne 0 -or !(Get-Item -LiteralPath $stderr).Length) {
            throw "$flag accepted an unexpected argument."
        }
    }
    'PASS top-level help, structured build identity and invalid informational options.'
    $counter = Join-Path $prototype 'counter4.q3a'
    $badCounter = Join-Path $prototype 'counter4-fail.q3a'
    $scalar = Join-Path $prototype 'bmc-scalar.q3a'
    $sequence = Join-Path $prototype 'lower-sva-sequences.q3a'
    $proof = Join-Path $scratch.FullName 'proof'
    $missingParent = Join-Path $scratch.FullName 'missing/proof'
    $missingManifest = Join-Path $scratch.FullName 'missing.q3a'

    $defaultRoot = Join-Path $scratch.FullName 'q3aformal-results'
    $savedPaths = @()
    foreach ($job in @(
        @{ Status = 'BOUNDED_FAIL'; Args = @($badCounter, '--engine', 'bmc', '--property', 'p_wraps_to_zero', '--frames', '1') },
        @{ Status = 'BOUNDED_FAIL'; Args = @($badCounter, '--engine', 'bmc', '--property', 'p_wraps_to_zero', '--frames', '1') },
        @{ Status = 'FAIL'; Args = @($scalar, '--engine', 'induction', '--property', 'p_can_fail',
            '--output-prefix', (Join-Path $scratch.FullName 'default-base-fail')) },
        @{ Status = 'FAIL'; Args = @((Join-Path $prototype 'pdr-pipeline.q3a'), '--engine', 'pdr',
            '--property', 'p_bad', '--evidence-dir', (Join-Path $scratch.FullName 'default-pdr-proof')) }
    )) {
        $commandArgs = $job.Args
        $result = & $exe prove @commandArgs 2> $stderr | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $result.status -cne $job.Status -or !$result.bundle_dir -or
            ![IO.Path]::IsPathFullyQualified($result.bundle_dir) -or
            !(Test-Path -LiteralPath (Join-Path $defaultRoot (Split-Path -Leaf $result.bundle_dir)) -PathType Container) -or
            $savedPaths -ccontains $result.bundle_dir) {
            throw "Expected a distinct default witness bundle for $($job.Status): $result."
        }
        $savedPaths += $result.bundle_dir
        $checked = & $exe --verify-bundle $result.bundle_dir 2> $stderr
        if ($LASTEXITCODE -ne 0 -or $checked -cnotcontains 'Q3A_BUNDLE_SOURCE_MODEL VERIFIED' -or
            $checked -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED') {
            throw "Default witness did not reopen: $checked $(Get-Content $stderr -Raw)"
        }
    }
    $legacy = & $exe --bmc $badCounter --property p_wraps_to_zero --frames 1 2> $stderr
    if ($LASTEXITCODE -ne 0 -or $legacy -cmatch '^Q3A_BUNDLE_CREATED' -or
        @(Get-ChildItem -LiteralPath $defaultRoot -Directory).Count -ne $savedPaths.Count) {
        throw 'Legacy BMC unexpectedly selected a default bundle destination.'
    }
    $blocked = New-Item -ItemType Directory -Path (Join-Path $scratch.FullName 'blocked')
    $sentinel = Join-Path $blocked.FullName 'q3aformal-results'
    'keep this file' | Set-Content -LiteralPath $sentinel
    Push-Location -LiteralPath $blocked.FullName
    try {
        $failure = & $exe prove $badCounter --engine bmc --property p_wraps_to_zero --frames 1 2> $stderr |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 3 -or $failure.status -cne 'ENGINE_ERROR' -or $failure.bundle_dir -or
            (Get-Content -LiteralPath $sentinel) -cne 'keep this file') {
            throw 'A failed automatic publication returned success, advertised a bundle, or overwrote a file.'
        }
    } finally {
        Pop-Location
    }
    'PASS default witness persistence and source-backed replay for BMC, k-induction and PDR'

    Check-Prove 'checked DRAT proof' 0 'PROVEN' 'p_wraps_to_zero' @(
        $counter, '--engine', 'induction', '--property', 'p_wraps_to_zero', '--output-prefix', $proof)
    Check-Prove 'replayed counterexample' 0 'BOUNDED_FAIL' 'p_wraps_to_zero' @(
        $badCounter, '--engine', 'bmc', '--property', 'p_wraps_to_zero', '--frames', '1')
    Check-Prove 'replayed reachable induction base failure' 0 'FAIL' 'p_can_fail' @(
        $scalar, '--engine', 'induction', '--property', 'p_can_fail',
        '--output-prefix', (Join-Path $scratch.FullName 'base-fail'))
    Check-Prove 'replayed cover' 0 'COVERED' 'property_check_12' @(
        $sequence, '--engine', 'bmc', '--property', 'property_check_12', '--frames', '2')
    Check-Prove 'bounded pass' 1 'BOUNDED_PASS' 'p_always_true' @(
        $scalar, '--engine', 'bmc', '--property', 'p_always_true', '--frames', '3')
    Check-Prove 'bounded cover miss' 1 'BOUNDED_COVER_MISS' 'property_check_12' @(
        $sequence, '--engine', 'bmc', '--property', 'property_check_12', '--frames', '0')
    Check-Prove 'failed induction step' 1 'NOT_1_INDUCTIVE' 'p_past_a' @(
        (Join-Path $prototype 'bmc-past.q3a'), '--engine', 'induction', '--property', 'p_past_a',
        '--output-prefix', (Join-Path $scratch.FullName 'step-fail'))
    Check-Prove 'inconsistent assumptions' 1 'INCONSISTENT_MODEL_OR_ASSUMPTIONS' 'p_assert_a' @(
        (Join-Path $prototype 'bmc-conflict.q3a'), '--engine', 'bmc', '--property', 'p_assert_a', '--frames', '1')
    Check-Prove 'missing project' 2 'SETUP_ERROR' 'p_wraps_to_zero' @(
        $missingManifest, '--engine', 'bmc', '--property', 'p_wraps_to_zero', '--frames', '1')
    foreach ($name in 'disable_iff', 'multiclock', 'unlisted_sva', 'xz_data') {
        $unsupported = Join-Path $prototype "benchmark/fixtures/B05_${name}_reject.q3a"
        Check-Prove "unsupported $name" 2 'UNSUPPORTED' 'p_reject' @(
            $unsupported, '--engine', 'bmc', '--property', 'p_reject', '--frames', '1') -ExpectedDiagnostic 'Q3A_PARSE_ERROR'
    }
    Check-Prove 'unsupported latch in lowering' 2 'UNSUPPORTED' 'p_reject' @(
        (Join-Path $prototype 'lower-latch-reject.q3a'), '--engine', 'bmc', '--property', 'p_reject',
        '--frames', '1') -ExpectedDiagnostic 'Q3A_LOWERING_ERROR'
    Check-Prove 'missing design top in elaboration' 2 'ELABORATION_ERROR' 'p_reject' @(
        (Join-Path $prototype 'hierarchy-missing-top.q3a'), '--engine', 'bmc', '--property', 'p_reject',
        '--frames', '1') -ExpectedDiagnostic 'Q3A_ELABORATION_ERROR'
    $widthMismatch = Join-Path $prototype 'hierarchy-width-mismatch.q3a'
    foreach ($engine in 'pdr', 'induction') {
        $engineFlags = if ($engine -ceq 'pdr') {
            @('--evidence-dir', (Join-Path $scratch.FullName 'invalid-certificate'))
        } else {
            @('--output-prefix', (Join-Path $scratch.FullName 'invalid-induction'))
        }
        Check-Prove "port width mismatch in $engine" 2 'ELABORATION_ERROR' 'p_reject' (
            @($widthMismatch, '--engine', $engine, '--property', 'p_reject') + $engineFlags) -ExpectedDiagnostic 'Q3A_ELABORATION_ERROR'
    }
    $malformed = Join-Path $scratch.FullName 'malformed.q3a'
    @('Q3AFORMAL_PROJECT 1', 'top malformed', 'source "malformed.sv"') |
        Set-Content -LiteralPath $malformed
    @('module malformed(input logic clk)', 'endmodule') |
        Set-Content -LiteralPath (Join-Path $scratch.FullName 'malformed.sv')
    Check-Prove 'invalid grammar' 2 'SETUP_ERROR' 'p_reject' @(
        $malformed, '--engine', 'bmc', '--property', 'p_reject', '--frames', '1') -ExpectedDiagnostic 'Q3A_PARSE_ERROR'
    '/* unterminated comment' | Set-Content -LiteralPath (Join-Path $scratch.FullName 'malformed.sv')
    Check-Prove 'invalid lexical token stream' 2 'SETUP_ERROR' 'p_reject' @(
        $malformed, '--engine', 'bmc', '--property', 'p_reject', '--frames', '1') -ExpectedDiagnostic 'Q3A_LEX_ERROR'
    Check-Prove 'missing options' 2 'SETUP_ERROR' '' @($counter)
    Check-Prove 'escaped property text' 2 'SETUP_ERROR' 'unknown\label' @(
        $scalar, '--engine', 'bmc', '--property', 'unknown\label', '--frames', '1')
    Check-Prove 'engine artifact failure' 3 'ENGINE_ERROR' 'p_wraps_to_zero' @(
        $counter, '--engine', 'induction', '--property', 'p_wraps_to_zero', '--output-prefix', $missingParent)

    $originalLimit = $env:Q3A_MEMORY_LIMIT_MIB
    try {
        $env:Q3A_MEMORY_LIMIT_MIB = '1'
        $limitedPrefix = Join-Path $scratch.FullName 'limited-proof'
        $limitedCertificate = Join-Path $scratch.FullName 'limited-certificate'
        $limitedBundle = Join-Path $scratch.FullName 'limited-witness'
        Check-Prove 'bmc memory limit' 1 'RESOURCE_LIMIT' 'p_wraps_to_zero' @(
            $counter, '--engine', 'bmc', '--property', 'p_wraps_to_zero', '--frames', '1000',
            '--bundle-dir', $limitedBundle) 'memory'
        Check-Prove 'induction memory limit' 1 'RESOURCE_LIMIT' 'p_wraps_to_zero' @(
            $counter, '--engine', 'induction', '--property', 'p_wraps_to_zero', '--k', '1000',
            '--output-prefix', $limitedPrefix) 'memory'
        Check-Prove 'pdr memory limit' 1 'RESOURCE_LIMIT' 'p_safe' @(
            (Join-Path $prototype 'pdr-pipeline.q3a'), '--evidence-dir', $limitedCertificate) 'memory'
        if ((Test-Path -LiteralPath $limitedBundle) -or (Test-Path -LiteralPath $limitedCertificate) -or
            @(Get-ChildItem -LiteralPath $scratch.FullName -Filter 'limited-proof*').Count -ne 0) {
            throw 'An interrupted command published a witness or proof.'
        }
    } finally {
        $env:Q3A_MEMORY_LIMIT_MIB = $originalLimit
    }
    Check-Prove 'pdr depth bound' 1 'UNKNOWN' 'p_safe' @(
        (Join-Path $prototype 'pdr-pipeline.q3a'), '--engine', 'pdr', '--property', 'p_safe',
        '--max-depth', '1', '--evidence-dir', (Join-Path $scratch.FullName 'depth-certificate'))

    Check-Prove 'invalid deadline' 2 'SETUP_ERROR' '' @($counter, '--timeout-ms', '0')
    Check-Prove 'overflowing deadline' 2 'SETUP_ERROR' '' @($counter, '--timeout-ms', '18446744073709551616')
    Check-Prove 'missing deadline' 2 'SETUP_ERROR' '' @($counter, '--timeout-ms')
    Check-Prove 'replayed witness before deadline' 0 'BOUNDED_FAIL' 'p_wraps_to_zero' @(
        $badCounter, '--timeout-ms', '30000', '--engine', 'bmc', '--property',
        'p_wraps_to_zero', '--frames', '1') -ExpectedTimeout 30000

    $timedWave = Join-Path $scratch.FullName 'timed.vcd'
    $timedBundle = Join-Path $scratch.FullName 'timed-bundle'
    $timedProof = Join-Path $scratch.FullName 'timed-proof'
    $inductionRecord = Join-Path $scratch.FullName 'timed-induction.json'
    $timedCertificate = Join-Path $scratch.FullName 'timed-certificate'
    $pdrRecord = Join-Path $scratch.FullName 'timed-pdr.json'
    Check-Prove 'bmc deadline' 1 'TIMEOUT' 'p_wraps_to_zero' @(
        $badCounter, '--timeout-ms', '1', '--engine', 'bmc', '--property', 'p_wraps_to_zero',
        '--frames', '10000', '--vcd', $timedWave, '--bundle-dir', $timedBundle) -ExpectedTimeout 1
    Check-Prove 'induction deadline' 1 'TIMEOUT' 'p_wraps_to_zero' @(
        $counter, '--timeout-ms', '1', '--run-record', $inductionRecord, '--engine', 'induction', '--property', 'p_wraps_to_zero',
        '--k', '5000', '--output-prefix', $timedProof) -ExpectedTimeout 1

    $slowPdr = Join-Path $scratch.FullName 'slow-pdr.q3a'
    @('Q3AFORMAL_PROJECT 2', 'top slow_pdr', 'source systemverilog "slow-pdr.sv"',
      'option engine pdr', 'option property p_valid') | Set-Content -LiteralPath $slowPdr
    & {
        'module slow_pdr(input logic clk, input logic [63:0] data);'
        foreach ($index in 0..127) {
            "logic [63:0] q$index;"
            "always_ff @(posedge clk) begin q$index <= data; end"
        }
        'p_valid: assert property (@(posedge clk) (q0 == q0));'
        'endmodule'
    } | Set-Content -LiteralPath (Join-Path $scratch.FullName 'slow-pdr.sv')
    Check-Prove 'manifest-selected pdr deadline' 1 'TIMEOUT' 'p_valid' @(
        $slowPdr, '--timeout-ms', '1', '--run-record', $pdrRecord, '--evidence-dir', $timedCertificate) -ExpectedTimeout 1
    foreach ($record in $inductionRecord, $pdrRecord) {
        $reopened = @(& $exe --verify-bundle $record)
        if ($LASTEXITCODE -ne 0 -or $reopened -cnotcontains 'Q3A_RUN_RECORDED_STATUS TIMEOUT' -or
            $reopened -cnotcontains 'Q3A_RUN_EVIDENCE INTERRUPTION_METADATA_ONLY') {
            throw "Could not reopen deadline record. $reopened"
        }
    }
    if ((Test-Path -LiteralPath $timedWave) -or (Test-Path -LiteralPath $timedBundle) -or
        (Test-Path -LiteralPath $timedCertificate) -or
        @(Get-ChildItem -LiteralPath $scratch.FullName -Filter 'timed-proof*').Count -ne 0) {
        throw 'A timed-out engine left published proof or waveform output.'
    }
} finally {
    Pop-Location
    $resolved = (Resolve-Path -LiteralPath $scratch.FullName).ProviderPath
    if ($resolved -eq $scratch.FullName -and $scratch.Name -like 'q3a-prove-cli-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
