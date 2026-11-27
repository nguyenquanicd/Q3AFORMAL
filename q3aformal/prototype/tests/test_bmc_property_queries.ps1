$ErrorActionPreference = 'Stop'

$prototypeRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $prototypeRoot 'bin\q3aformal-sourcecheck.exe'
$manifest = Join-Path $prototypeRoot 'bmc-scalar.q3a'

$farFuture = & $executable --bmc (Join-Path $prototypeRoot 'rtl-far-future-assumption.q3a') `
    --property p_grant --frames 1
if ($LASTEXITCODE -ne 0 -or $farFuture -notcontains 'Q3A_BMC_STATUS BOUNDED_FAIL' -or
    $farFuture -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE' -or
    $farFuture -notcontains 'Q3A_BMC_REPLAY VALIDATED') {
    throw "Expected a replayed scalar failure with an unfinished far-future assumption:`n$($farFuture -join "`n")"
}

$alwaysTrue = & $executable --bmc $manifest --property p_always_true --frames 3
if ($LASTEXITCODE -ne 0) {
    throw "Bounded scalar assertion command failed:`n$($alwaysTrue -join "`n")"
}
if (-not ($alwaysTrue -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "Tautological property must have no bounded counterexample:`n$($alwaysTrue -join "`n")"
}

$canFail = & $executable --bmc $manifest --property p_can_fail --frames 3
if ($LASTEXITCODE -ne 0) {
    throw "Bounded scalar assertion command failed:`n$($canFail -join "`n")"
}
if (-not ($canFail -contains 'Q3A_BMC_STATUS BOUNDED_FAIL')) {
    throw "Unconstrained input property must have a bounded counterexample:`n$($canFail -join "`n")"
}
if (-not ($canFail | Where-Object { $_ -match '^Q3A_BMC_COUNTEREXAMPLE_CANDIDATE frame=\d+$' })) {
    throw "Bounded failure should identify a candidate frame:`n$($canFail -join "`n")"
}
if (-not ($canFail -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A reported failure must pass independent frame replay:`n$($canFail -join "`n")"
}

$assumptionManifest = Join-Path $prototypeRoot 'bmc-assumption.q3a'
$assumed = & $executable --bmc $assumptionManifest --property p_assert_a --frames 2
if ($LASTEXITCODE -ne 0 -or
    -not ($assumed -contains 'Q3A_BMC_STATUS BOUNDED_PASS')) {
    throw "A scalar environment assumption must constrain the assertion query:`n$($assumed -join "`n")"
}

$pastManifest = Join-Path $prototypeRoot 'bmc-past.q3a'
$pastWarmup = & $executable --bmc $pastManifest --property p_past_a --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($pastWarmup -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
    -not ($pastWarmup -contains 'Q3A_BMC_VACUITY VACUOUS')) {
    throw "A guarded `$past property must be inactive before its first history sample:`n$($pastWarmup -join "`n")"
}
$pastActive = & $executable --bmc $pastManifest --property p_past_a --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($pastActive -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($pastActive -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
    throw "The guarded `$past property must become active after its first history sample:`n$($pastActive -join "`n")"
}

$alignmentManifest = Join-Path $prototypeRoot 'lower-sva-alignment.q3a'
$overlapped = & $executable --bmc $alignmentManifest --property p_overlapped_chain --frames 3
if ($LASTEXITCODE -ne 0 -or
    -not ($overlapped -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($overlapped -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "Overlapped sequence implication should find an in-bound counterexample:`n$($overlapped -join "`n")"
}
$shortBound = & $executable --bmc $alignmentManifest --property p_overlapped_chain --frames 2
if ($LASTEXITCODE -ne 0 -or
    -not ($shortBound -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
    -not ($shortBound -contains 'Q3A_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE')) {
    throw "An unobserved consequent horizon must be reported as incomplete, not as a complete pass:`n$($shortBound -join "`n")"
}
$nonoverlapped = & $executable --bmc $alignmentManifest --property p_nonoverlapped_chain --frames 4
if ($LASTEXITCODE -ne 0 -or
    -not ($nonoverlapped -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($nonoverlapped -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "Non-overlapped sequence implication should find an in-bound counterexample:`n$($nonoverlapped -join "`n")"
}
$boundedRepeat = & $executable --bmc $alignmentManifest --property p_bounded_repeat --frames 3
if ($LASTEXITCODE -ne 0 -or
    -not ($boundedRepeat -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($boundedRepeat -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "Each bounded antecedent match end must create a consequent obligation:`n$($boundedRepeat -join "`n")"
}
$sequenceAssumptionManifest = Join-Path $prototypeRoot 'bmc-sequence-assumption.q3a'
$assumedSequence = & $executable --bmc $sequenceAssumptionManifest --property p_overlapped --frames 4
if ($LASTEXITCODE -ne 0 -or
    -not ($assumedSequence -contains 'Q3A_BMC_STATUS BOUNDED_PASS') -or
    -not ($assumedSequence -contains 'Q3A_BMC_VACUITY NONVACUOUS')) {
    throw "Scalar assumptions should constrain the consequent of an implication query:`n$($assumedSequence -join "`n")"
}

$stateFailureManifest = Join-Path $prototypeRoot 'bmc-state-failure.q3a'
$stateFailure = & $executable --bmc $stateFailureManifest --property p_q_tracks_a --frames 1
if ($LASTEXITCODE -ne 0 -or
    -not ($stateFailure -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($stateFailure -contains 'Q3A_BMC_REPLAY VALIDATED') -or
    -not ($stateFailure | Where-Object { $_ -match '^Q3A_BMC_TRACE_SIGNAL frame=1 name=q width=1 value=0x0$' })) {
    throw "The independently replayed trace must preserve a sequential RTL failure:`n$($stateFailure -join "`n")"
}

$vcdPath = Join-Path ([System.IO.Path]::GetTempPath()) (
    'q3aformal-witness-' + [guid]::NewGuid().ToString('N') + '.vcd')
$htmlPath = [System.IO.Path]::ChangeExtension($vcdPath, '.html')
try {
    $vcdFailure = & $executable --bmc $stateFailureManifest `
        --property p_q_tracks_a --frames 1 --vcd $vcdPath --html $htmlPath
    if ($LASTEXITCODE -ne 0 -or
        -not ($vcdFailure -contains 'Q3A_BMC_WAVEFORM WRITTEN') -or
        -not ($vcdFailure -contains 'Q3A_BMC_WAVEFORM_HTML WRITTEN') -or
        -not (Test-Path -LiteralPath $vcdPath) -or
        -not (Test-Path -LiteralPath $htmlPath)) {
        throw "A replay-validated counterexample should be exported to VCD and HTML:`n$($vcdFailure -join "`n")"
    }
    $vcdText = Get-Content -LiteralPath $vcdPath -Raw
    foreach ($requiredText in @(
        '$timescale 1ns $end',
        '$scope module bmc_state_failure_top $end',
        '$enddefinitions $end',
        '#0',
        '#1'
    )) {
        if (-not $vcdText.Contains($requiredText)) {
            throw "VCD output is missing required structure '$requiredText':`n$vcdText"
        }
    }
    if ($vcdText -notmatch '\$var wire 1 v\d+ \\q ' -or
        $vcdText -notmatch '\$var wire 1 v\d+ \\clk ' -or
        $vcdText -notmatch '\$var event 1 e1 \\clk ') {
        throw "VCD should include the sampled clock bit and a separate clock event."
    }
    $htmlText = Get-Content -LiteralPath $htmlPath -Raw
    foreach ($requiredText in @(
        '<!doctype html>',
        'Q3AFormal waveform',
        'const traceFrames = 2',
        'const witnessFrame = 1',
        'const sampleClockNames = ["clk"]',
        'clk (sampled bit)',
        'id="witness"',
        'const signalData = [',
        'id="wave"',
        'Filter signals by name',
        'Click the waveform to move the cursor'
    )) {
        if (-not $htmlText.Contains($requiredText)) {
            throw "Self-contained waveform viewer is missing '$requiredText'."
        }
    }
    if ($htmlText -match 'https?://|<script[^>]+src=') {
        throw 'Waveform viewer must work offline without remote scripts or assets.'
    }

    $sourcePath = Join-Path $prototypeRoot 'corpus\source-model-vectors\bmc_state_failure.sv'
    $originalSource = Get-Content -LiteralPath $sourcePath -Raw
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $overwriteAttempt = & $executable --bmc $stateFailureManifest `
        --property p_q_tracks_a --frames 1 --vcd $sourcePath 2>&1
    $overwriteExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    $preservedSource = Get-Content -LiteralPath $sourcePath -Raw
    if ($overwriteExitCode -eq 0 -or
        -not (($overwriteAttempt -join "`n") -match 'must not overwrite an RTL source') -or
        $preservedSource -cne $originalSource) {
        throw "VCD export must refuse to overwrite project RTL:`n$($overwriteAttempt -join "`n")"
    }

    $passVcdPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'q3aformal-no-witness-' + [guid]::NewGuid().ToString('N') + '.vcd')
    $passHtmlPath = [System.IO.Path]::ChangeExtension($passVcdPath, '.html')
    $passOutput = & $executable --bmc $prototypeRoot\bmc-scalar.q3a `
        --property p_always_true --frames 1 --vcd $passVcdPath --html $passHtmlPath
    if ($LASTEXITCODE -ne 0 -or
        -not ($passOutput -contains 'Q3A_BMC_WAVEFORM NOT_WRITTEN reason=no_validated_witness') -or
        -not ($passOutput -contains 'Q3A_BMC_WAVEFORM_HTML NOT_WRITTEN reason=no_validated_witness') -or
        (Test-Path -LiteralPath $passVcdPath) -or
        (Test-Path -LiteralPath $passHtmlPath)) {
        throw "A query without a witness must not create empty waveform files:`n$($passOutput -join "`n")"
    }
} finally {
    if (Test-Path -LiteralPath $vcdPath) {
        Remove-Item -LiteralPath $vcdPath -Force
    }
    if (Test-Path -LiteralPath $htmlPath) {
        Remove-Item -LiteralPath $htmlPath -Force
    }
    if ($passVcdPath -and (Test-Path -LiteralPath $passVcdPath)) {
        Remove-Item -LiteralPath $passVcdPath -Force
    }
    if ($passHtmlPath -and (Test-Path -LiteralPath $passHtmlPath)) {
        Remove-Item -LiteralPath $passHtmlPath -Force
    }
}

$casezManifest = Join-Path $prototypeRoot 'bmc-casez-replay.q3a'
$casezFailure = & $executable --bmc $casezManifest --property p_output_is_zero --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($casezFailure -contains 'Q3A_BMC_STATUS BOUNDED_FAIL') -or
    -not ($casezFailure -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "Witness replay must independently evaluate casez_match and vector constants:`n$($casezFailure -join "`n")"
}

$sequenceManifest = Join-Path $prototypeRoot 'lower-sva-sequences.q3a'
$unobservedSequence = & $executable --bmc $sequenceManifest --property p_delay_two --frames 0
if ($LASTEXITCODE -ne 0 -or
    $unobservedSequence -notcontains 'Q3A_BMC_STATUS BOUNDED_PASS' -or
    $unobservedSequence -notcontains 'Q3A_BMC_VACUITY VACUOUS' -or
    $unobservedSequence -notcontains 'Q3A_BMC_BOUNDARY_OBLIGATIONS INCOMPLETE') {
    throw "An assertion with no complete sequence horizon must remain inactive within the bound:`n$($unobservedSequence -join "`n")"
}
$coverReached = & $executable --bmc $sequenceManifest --property property_check_12 --frames 2
if ($LASTEXITCODE -ne 0 -or
    -not ($coverReached -contains 'Q3A_BMC_STATUS COVERED') -or
    -not ($coverReached -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A reachable sequence cover must produce an independently replayed witness:`n$($coverReached -join "`n")"
}
$coverMiss = & $executable --bmc $sequenceManifest --property property_check_12 --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($coverMiss -contains 'Q3A_BMC_STATUS UNKNOWN') -or
    -not ($coverMiss -contains 'Q3A_BMC_COVER_RESULT NOT_FOUND_WITHIN_BOUND') -or
    -not ($coverMiss -contains 'Q3A_BMC_COVER_SCOPE BOUNDED boundary_limited=yes') -or
    ($coverMiss -contains 'Q3A_BMC_STATUS UNREACHABLE')) {
    throw "A finite cover miss must not be reported as unreachability:`n$($coverMiss -join "`n")"
}

$scalarCoverManifest = Join-Path $prototypeRoot 'bmc-scalar-cover.q3a'
$scalarCover = & $executable --bmc $scalarCoverManifest --property property_check_1 --frames 0
if ($LASTEXITCODE -ne 0 -or
    -not ($scalarCover -contains 'Q3A_BMC_STATUS COVERED') -or
    -not ($scalarCover -contains 'Q3A_BMC_REPLAY VALIDATED')) {
    throw "A reachable scalar cover must produce an independently replayed witness:`n$($scalarCover -join "`n")"
}

'PASS: scalar/sequence queries, replay, assumptions, vacuity, boundaries, cover search, and offline waveform export behave as expected.'
