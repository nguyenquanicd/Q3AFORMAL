#requires -Version 7.0
param([string]$ExecutablePath, [string]$PreFixExecutablePath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $prototype
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path $prototype 'bin/q3aformal-sourcecheck.exe' }
$previous = if ($PreFixExecutablePath) { (Resolve-Path -LiteralPath $PreFixExecutablePath).Path }
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-source-required-' + [guid]::NewGuid().ToString('N')))).FullName
$stderr = Join-Path $root 'stderr.txt'

function Check-Bundle($Path, $Required, $Code, $Lines, $Failure) {
    $options = @(if ($Required) { '--require-source-model' })
    $output = @(& $exe --verify-bundle $Path @options 2> $stderr)
    $exitCode = $LASTEXITCODE
    foreach ($line in $Lines) {
        if ($output -cnotcontains $line) { throw "Missing '$line' for $Path. Exit $exitCode. $output. $(Get-Content -LiteralPath $stderr -Raw)" }
    }
    if ($exitCode -ne $Code -or ($Failure -and (
        $output -ccontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
        (Get-Content -LiteralPath $stderr -Raw) -cnotmatch [regex]::Escape($Failure)))) {
        throw "Unexpected verification outcome for $Path. Exit $exitCode. $output. $(Get-Content $stderr -Raw)"
    }
}

function Edit-Manifest($Bundle, [scriptblock]$Edit) {
    $path = Join-Path $Bundle 'manifest.json'
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    & $Edit $manifest
    $manifest | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $path -Encoding utf8
    (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() |
        Set-Content -LiteralPath (Join-Path $Bundle 'manifest.sha256') -Encoding ascii
}

function Copy-OlderEncoderBundle($Original, $Destination) {
    Copy-Item -LiteralPath $Original -Destination $Destination -Recurse
    Edit-Manifest $Destination {
        param($manifest)
        ($manifest.components | Where-Object id -CEQ 'sat_bit_blaster').source_sha256 = '0' * 64
    }
}

function Change-QueryBytes($Bundle, $QueryId) {
    Edit-Manifest $Bundle {
        param($manifest)
        $query = $manifest.queries | Where-Object id -CEQ $QueryId
        $record = $manifest.artifacts | Where-Object path -CEQ $query.cnf_path
        if (!$record) { throw "Missing test query $QueryId." }
        $path = Join-Path $Bundle $query.cnf_path
        Add-Content -LiteralPath $path -Value 'c regression: saved query differs' -Encoding utf8
        $record.size_bytes = (Get-Item -LiteralPath $path).Length
        $record.sha256 = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
        $query.cnf_sha256 = $record.sha256
    }
}

try {
    $required = @('Q3A_BUNDLE_SOURCE_MODEL VERIFIED', 'Q3A_BUNDLE_STATUS REVALIDATED')
    $witness = Join-Path $root 'witness'
    $arguments = @((Join-Path $prototype 'counter4-fail.q3a'), '--engine', 'bmc', '--property', 'p_wraps_to_zero',
        '--frames', '1', '--bundle-dir', $witness)
    $result = & $exe prove @arguments 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'BOUNDED_FAIL') { throw 'Could not generate fresh witness.' }
    Check-Bundle $witness $true 0 $required
    'PASS fresh witness reproduces source and replays'

    $olderWitness = Join-Path $root 'older-encoder-witness'
    Copy-OlderEncoderBundle $witness $olderWitness
    Check-Bundle $olderWitness $false 0 @('Q3A_BUNDLE_BMC_WITNESS_QUERY UNVERIFIED', 'Q3A_BUNDLE_STATUS REVALIDATED')
    Check-Bundle $olderWitness $true 0 ($required + 'Q3A_BUNDLE_BMC_WITNESS_QUERY VERIFIED')
    Change-QueryBytes $olderWitness 'property'
    Check-Bundle $olderWitness $true 1 @('Q3A_BUNDLE_SOURCE_MODEL VERIFIED') 'regenerated BMC query CNF differs'
    'PASS strict BMC witness requires matching CNF across encoder builds; changed bytes rejected'

    $bounded = Join-Path $root 'bounded-pass'
    $arguments = @((Join-Path $prototype 'known-pass-combinational.q3a'), '--engine', 'bmc', '--property',
        'p_y_implies_a', '--frames', '2', '--bundle-dir', $bounded)
    $result = & $exe prove @arguments 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or $result.status -cne 'BOUNDED_PASS') { throw 'Could not generate bounded query.' }
    $olderBounded = Join-Path $root 'older-encoder-bounded-pass'
    Copy-OlderEncoderBundle $bounded $olderBounded
    Check-Bundle $olderBounded $false 0 @('Q3A_BUNDLE_STATUS HISTORIC')
    Check-Bundle $olderBounded $true 0 ($required + 'Q3A_BUNDLE_BMC_QUERY REVALIDATED status=BOUNDED_PASS bound=2')
    'PASS strict bounded UNSAT query reexecutes across encoder builds'

    $older = Join-Path $root 'older-source-fingerprint'
    Copy-Item -LiteralPath $witness -Destination $older -Recurse
    Edit-Manifest $older {
        param($manifest)
        ($manifest.components | Where-Object id -CEQ 'source_manager').source_sha256 = '0' * 64
    }
    Check-Bundle $older $false 0 @('Q3A_BUNDLE_SOURCE_MODEL UNVERIFIED', 'Q3A_BUNDLE_STATUS REVALIDATED')
    Check-Bundle $older $true 0 $required
    'PASS exact model from a different compiler fingerprint is reproducible in strict mode'

    $proof = Join-Path $root 'proof'
    $arguments = @((Join-Path $prototype 'known-pass-combinational.q3a'), '--engine', 'induction', '--property',
        'p_y_implies_a', '--output-prefix', (Join-Path $root 'induction'), '--bundle-dir', $proof)
    $result = & $exe prove @arguments 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.status -cne 'PROVEN') { throw 'Could not generate fresh proof.' }
    Check-Bundle $proof $true 0 $required
    'PASS fresh checked proof reproduces source'

    $olderProof = Join-Path $root 'older-encoder-proof'
    Copy-OlderEncoderBundle $proof $olderProof
    Check-Bundle $olderProof $false 0 @('Q3A_BUNDLE_STATUS HISTORIC')
    Check-Bundle $olderProof $true 0 $required
    Change-QueryBytes $olderProof 'step'
    Check-Bundle $olderProof $true 1 @('Q3A_BUNDLE_SOURCE_MODEL VERIFIED') 'regenerated induction query CNF differs from the saved step obligation'
    'PASS strict induction rechecks both matching obligations across encoder builds; changed step bytes rejected'

    $step = Join-Path $root 'step-countermodel'
    $arguments = @((Join-Path $prototype 'bmc-past.q3a'), '--engine', 'induction', '--property', 'p_past_a',
        '--output-prefix', (Join-Path $root 'step'), '--bundle-dir', $step)
    $result = & $exe prove @arguments 2> $stderr | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or $result.status -cne 'NOT_1_INDUCTIVE') { throw 'Could not generate step countermodel.' }
    $olderStep = Join-Path $root 'older-encoder-step-countermodel'
    Copy-OlderEncoderBundle $step $olderStep
    Check-Bundle $olderStep $false 0 @('Q3A_BUNDLE_STATUS HISTORIC')
    Check-Bundle $olderStep $true 0 ($required + 'Q3A_BUNDLE_INDUCTION_WITNESS_QUERY VERIFIED id=step')
    'PASS strict non-induction result checks saved base proof and replays step against matching queries'

    $historic = Join-Path $root 'historic-checker'
    Copy-Item -LiteralPath $proof -Destination $historic -Recurse
    Edit-Manifest $historic {
        param($manifest)
        $manifest.checker.fingerprint_sha256 = '0' * 64
        ($manifest.components | Where-Object id -CEQ 'proof_checker').source_sha256 = '0' * 64
    }
    Check-Bundle $historic $false 0 @('Q3A_BUNDLE_STATUS HISTORIC')
    Check-Bundle $historic $true 0 ($required + 'Q3A_BUNDLE_REVALIDATION ACCEPTED proof_artifacts=2')
    'PASS strict verification checks both original proofs with the current checker across checker builds'

    $unsupportedFormat = Join-Path $root 'unsupported-proof-schema'
    Copy-Item -LiteralPath $historic -Destination $unsupportedFormat -Recurse
    Edit-Manifest $unsupportedFormat {
        param($manifest)
        $manifest.checker.proof_artifact_schema = '99'
    }
    Check-Bundle $unsupportedFormat $true 1 @('Q3A_BUNDLE_SOURCE_MODEL VERIFIED') 'could not revalidate evidence'
    'PASS strict mode rejects an unsupported DRAT artifact schema'

    $unsupportedChecker = Join-Path $root 'unsupported-proof-checker'
    Copy-Item -LiteralPath $historic -Destination $unsupportedChecker -Recurse
    Edit-Manifest $unsupportedChecker {
        param($manifest)
        $manifest.checker.id = 'legacy-unsupported-checker'
    }
    Check-Bundle $unsupportedChecker $true 1 @('Q3A_BUNDLE_SOURCE_MODEL VERIFIED') 'could not revalidate evidence'
    'PASS strict mode rejects an unsupported DRAT checker identifier'

    $oldModel = Join-Path $repo 'evidence/known-pass/run-bundle-2026-11-16-v2'
    Check-Bundle $oldModel $true 1 @() 'regenerated T-IR differs from the saved model'
    'PASS strict mode rejects authentic archived proof whose T-IR does not reproduce'

    Edit-Manifest $historic {
        param($manifest)
        $saved = $manifest.artifacts | Where-Object { $_.role -ceq 'checked_drat_proof' -and $_.path.EndsWith('/step.q3adrat') }
        $path = Join-Path $historic $saved.path
        $lines = Get-Content -LiteralPath $path
        if ($lines -cnotcontains '0') { throw 'No empty clause in saved proof fixture.' }
        $lines | ForEach-Object { if ($_ -ceq '0') { '1 0' } else { $_ } } |
            Set-Content -LiteralPath $path -Encoding utf8
        $saved.size_bytes = (Get-Item -LiteralPath $path).Length
        $saved.sha256 = (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
    Check-Bundle $historic $true 1 @('Q3A_BUNDLE_SOURCE_MODEL VERIFIED') 'DRAT revalidation failed for step'
    'PASS strict mode rejects a rehashed DRAT body without a valid empty-clause derivation'

    $record = Join-Path $repo 'evidence/release/run-control-timeout-2026-11-24.json'
    Check-Bundle $record $false 0 @()
    Check-Bundle $record $true 1 @() 'needs a formal bundle directory'
    'PASS interruption records retain existing reopening and are rejected by source-required verification'

    & $exe --verify-bundle $witness --require-source-model --require-source-model 2> $stderr | Out-Null
    if ($LASTEXITCODE -ne 2 -or (Get-Content -LiteralPath $stderr -Raw) -cnotmatch 'usage: --verify-bundle') {
        throw 'Duplicate option was not rejected.'
    }

    if ($previous) {
        $manifest = Join-Path $root 'legacy.q3a'
        $source = Join-Path $root 'legacy.sv'
        $stale = Join-Path $root 'legacy-wrong-delay'
        @('Q3AFORMAL_PROJECT 2', 'top legacy', 'source systemverilog "legacy.sv"') |
            Set-Content -LiteralPath $manifest -Encoding utf8
        @('module legacy(input logic clk);',
            "    p_delay: cover property (@(posedge clk) 1'b1 ##1'd2 1'b1);",
            'endmodule') | Set-Content -LiteralPath $source -Encoding utf8
        $old = & $previous prove $manifest --engine bmc --property p_delay --frames 2 --bundle-dir $stale 2> $stderr |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $old.status -cne 'COVERED') { throw 'Could not reproduce the pre-fix witness.' }
        Check-Bundle $stale $false 0 @('Q3A_BUNDLE_SOURCE_MODEL UNVERIFIED', 'Q3A_BUNDLE_STATUS REVALIDATED',
            'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=3 candidate_frame=2')
        Check-Bundle $stale $true 1 @() 'regenerated T-IR differs from the saved model'
        $fixed = Join-Path $root 'fixed-delay'
        $result = & $exe prove $manifest --engine bmc --property p_delay --frames 0 --bundle-dir $fixed 2> $stderr |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $result.status -cne 'COVERED') { throw 'Could not reproduce corrected witness.' }
        Check-Bundle $fixed $true 0 ($required + 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=1 candidate_frame=0')
        'PASS authentic pre-fix witness rejected on source/model mismatch; corrected frame-zero witness accepted'
    }
} finally {
    $resolved = (Resolve-Path -LiteralPath $root).Path
    if ($resolved -ceq $root) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
