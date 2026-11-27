#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$ExecutablePath,
    [ValidateRange(1, 20)][int]$Repeats = 3
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$exe = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path }
    else { Join-Path (Split-Path -Parent $PSScriptRoot) 'bin/q3aformal-sourcecheck.exe' }
$manifest = Join-Path $PSScriptRoot 'fixtures/P1_elastic_pipeline.q3a'
$source = Join-Path $PSScriptRoot 'fixtures/P1_elastic_pipeline.sv'
$property = 'p_hold'
$lastFrame = 320
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$bundle = Join-Path $root 'bundle'
$vcd = Join-Path $root 'witness.vcd'
$trace = Join-Path $bundle "properties/$property/trace.q3atrace"
$page = Join-Path $root 'debug.html'
$workloadPath = Join-Path $root 'viewport-workload.json'

$arguments = @('prove', $manifest, '--parameter', 'DROP_STALL', '1', '--timeout-ms', '60000', '--engine', 'bmc',
    '--property', $property, '--frames', $lastFrame, '--bundle-dir', $bundle, '--vcd', $vcd, '--trace-all')
$engineLog = Join-Path $root 'engine.raw.txt'
$started = [Diagnostics.Stopwatch]::StartNew()
$solve = @(& $exe @arguments 2> $engineLog)
$code = $LASTEXITCODE
$started.Stop()
$summary = ($solve -join [char]10) | ConvertFrom-Json
$solve | Set-Content -LiteralPath (Join-Path $root 'run.json') -Encoding utf8
$lines = @(Get-Content -LiteralPath $engineLog)
$lines | Where-Object { $_ -notmatch '^Q3A_BMC_TRACE_(SIGNAL|FRAME) ' } |
    Set-Content -LiteralPath (Join-Path $root 'solve.txt') -Encoding utf8
Remove-Item -LiteralPath $engineLog
if ($code -ne 0 -or $summary.status -cne 'BOUNDED_FAIL' -or
    $lines -cnotcontains 'Q3A_BMC_REPLAY VALIDATED' -or $lines -cnotcontains 'Q3A_BMC_STATUS BOUNDED_FAIL') {
    throw 'The block workload did not produce a replay-validated counterexample.'
}
$verify = @(& $exe --verify-bundle $bundle)
if ($LASTEXITCODE -ne 0 -or $verify -cnotcontains 'Q3A_BUNDLE_STATUS REVALIDATED' -or
    $verify -cnotcontains 'Q3A_BUNDLE_TRACE_REPLAY VALIDATED frames=321 candidate_frame=320') {
    throw 'The counterexample did not revalidate at its declared terminal frame.'
}
$verify | Set-Content -LiteralPath (Join-Path $root 'revalidation.txt') -Encoding utf8

$native = & $exe trace window $trace --first 0 --last $lastFrame | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $native.candidate_frame -ne $lastFrame -or
    $native.frame_count -ne ($lastFrame + 1)) {
    throw 'The indexed trace has incorrect frame metadata.'
}
$roundtrip = & $exe trace import-vcd $vcd --q3a-roundtrip | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $roundtrip.provenance -cne 'q3a-roundtrip' -or $roundtrip.formal_evidence -or
    $roundtrip.samples.Count -ne $native.frame_count -or $roundtrip.signals.Count -ne ($native.signals.Count + 1)) {
    throw 'The VCD round trip has incorrect frame or signal metadata.'
}

$wires = @{}
foreach ($wire in ($roundtrip.signals | Where-Object type -cne 'event')) {
    if (($wire.scope -join '.') -cne 'p1_elastic_pipeline' -or $wires.ContainsKey($wire.name)) {
        throw "Unexpected VCD scope or duplicate name: $($wire.name)."
    }
    $wires[$wire.name] = $wire
}
foreach ($series in $native.signals) {
    if (!$wires.ContainsKey($series.name) -or $wires[$series.name].width -ne $series.width) {
        throw "Indexed trace and VCD disagree on the identity or width of $($series.name)."
    }
}

$shown = @('rst', 'in_valid', 'in_ready', 'in_data', 'out_valid', 'out_ready', 'out_data',
    'valid_0', 'valid_1', 'valid_2', 'ready_1', 'ready_2', 'ready_3', 'data_0', 'data_1', 'data_2')
$checkpoints = @(255, 256, 257, 319, 320, 0)
$positions = @{}
$vcdValues = @{}
$selectedFrames = @{}
$comparisonCount = 0
for ($frame = 0; $frame -le $lastFrame; ++$frame) {
    $sample = $roundtrip.samples[$frame]
    if ($sample.timestamp -cne [string]$frame) { throw "Incorrect VCD timestamp at $frame." }
    $samplingEdges = 0
    foreach ($change in $sample.changes) {
        $signal = $roundtrip.signals[$change[0]]
        if ($signal.type -ceq 'event') {
            if ($signal.name -cne 'clk' -or ($signal.scope -join '.') -cne 'p1_elastic_pipeline.__q3a_sampling' -or
                $change[1] -cne '1') { throw "Invalid VCD sampling event at $frame." }
            ++$samplingEdges
        } else {
            if ($change[1].Length -ne $signal.width) { throw "Invalid VCD width at frame $frame." }
            $vcdValues[$signal.name] = '0x{0:x}' -f [Convert]::ToUInt64($change[1], 2)
        }
    }
    if ($samplingEdges -ne 1) { throw "Expected one VCD sampling event at frame $frame." }
    foreach ($series in $native.signals) {
        $position = [int]$positions[$series.name]
        if ($position + 1 -lt $series.changes.Count -and $series.changes[$position + 1][0] -eq $frame) {
            $positions[$series.name] = ++$position
        }
        if ($vcdValues[$series.name] -cne $series.changes[$position][1]) {
            throw "VCD and indexed trace disagree at frame $frame for $($series.name)."
        }
        ++$comparisonCount
    }
    if ($frame -in $checkpoints) {
        $selectedFrames[$frame] = @{
            frame = $frame
            values = @($shown | ForEach-Object { $vcdValues[$_] })
            resetActive = $vcdValues.rst -ceq '0x1'
        }
    }
}

$before = $selectedFrames[319].values
$failed = $selectedFrames[320].values
if ($before[0] -cne '0x0' -or $before[4] -cne '0x1' -or $before[5] -cne '0x0' -or
    $before[6] -ceq $failed[6]) { throw 'The trace does not exhibit the expected changed stalled payload.' }

$assertionText = 'p_hold: assert property'
$assertion = Select-String -LiteralPath $source -SimpleMatch $assertionText
if (@($assertion).Count -ne 1) { throw 'The RTL does not identify one p_hold assertion.' }
$workload = [ordered]@{
    assertion = @{
        location = '{0}:{1}:{2}' -f (Split-Path -Leaf $source), $assertion.LineNumber,
            ($assertion.Line.IndexOf($assertionText, [StringComparison]::Ordinal) + 1)
        text = $assertionText
    }
    resetSignal = 'rst'
    signals = $shown
    span = 64
    steps = @($checkpoints | ForEach-Object { $selectedFrames[$_] })
}
$workload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $workloadPath -Encoding utf8
& $exe debug $bundle --reset rst high --group 'Output handshake' out_valid --group 'Output handshake' out_ready |
    Set-Content -LiteralPath $page -Encoding utf8
if ($LASTEXITCODE -ne 0) { throw 'Could not render verified bundle HTML.' }

$results = @(1..$Repeats | ForEach-Object {
    $result = & node (Join-Path $PSScriptRoot 'measure_debug_navigation.cjs') $page $trace --workload $workloadPath |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $result.viewports.Count -ne $checkpoints.Count -or
        $result.viewports[1].viewport_ranges -ne 0) {
        throw 'The renderer did not reuse the checkpoint-spanning viewport.'
    }
    $result
})
[ordered]@{
    schema = 'Q3AFORMAL_BLOCK_WITNESS_DEBUG_PILOT_1'
    source_executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
    manifest_sha256 = (Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()
    rtl_sha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
    bundle_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $bundle 'manifest.json')).Hash.ToLowerInvariant()
    native_trace_sha256 = (Get-FileHash -LiteralPath $trace).Hash.ToLowerInvariant()
    vcd_sha256 = (Get-FileHash -LiteralPath $vcd).Hash.ToLowerInvariant()
    debug_page_sha256 = (Get-FileHash -LiteralPath $page).Hash.ToLowerInvariant()
    solve_wall_ms = $started.Elapsed.TotalMilliseconds
    checked_cross_format_values = $comparisonCount
    checked_rendered_values_per_repeat = $checkpoints.Count * $shown.Count
    checked_reset_annotations_per_repeat = $checkpoints.Count
    checked_source_anchor = $workload.assertion.location
    witness_frame = $native.candidate_frame
    stalled_data_before = $before[6]
    data_at_failure = $failed[6]
    measurements = $results
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $root 'debug-pilot.json') -Encoding utf8
"PASS: $comparisonCount indexed/VCD values, $Repeats renderer repeats, and archived RTL assertion at $($workload.assertion.location)."
