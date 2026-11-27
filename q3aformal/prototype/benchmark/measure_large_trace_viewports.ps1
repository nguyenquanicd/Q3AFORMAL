#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputFile,
    [string]$Compiler = 'g++',
    [ValidateRange(1, 20)][int]$Repeats = 3
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$fixture = Join-Path $PSScriptRoot 'large_trace_fixture.cpp'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-large-trace-' + [guid]::NewGuid().ToString('N')))).FullName
$generator = Join-Path $root 'fixture.exe'
$trace = Join-Path $root 'trace.q3atrace'
$page = Join-Path $root 'page.html'
$workloadPath = Join-Path $root 'workload.json'

try {
    & $Compiler -std=c++17 -O2 $fixture (
        Join-Path $prototype 'source/bundle/indexed_trace.cpp') (
        Join-Path $prototype 'source/bundle/debug_view.cpp') -o $generator
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the trace fixture generator.' }
    & $generator $root
    if ($LASTEXITCODE -ne 0) { throw 'Could not write the synthetic trace fixture.' }

    $lanes = @(0..15 | ForEach-Object { $_ * 25 })
    $names = @($lanes | ForEach-Object { 'lane_{0:D3}' -f $_ })
    $signalOptions = @($names | ForEach-Object { '--signal'; $_ })
    $steps = @(512, 513, 2560, 4608, 6656, 512, 513 | ForEach-Object {
        $frame = $_
        [ordered]@{
            frame = $frame
            values = @($lanes | ForEach-Object { '0x{0:x}' -f ($frame * 1024 + $_) })
        }
    })
    $workload = [ordered]@{ signals = $names; span = 64; steps = $steps }
    $workload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $workloadPath -Encoding utf8

    foreach ($step in $steps) {
        $frame = $step.frame
        $native = & $exe trace window $trace --first $frame --last $frame @signalOptions | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $native.signals.Count -ne $names.Count) {
            throw "Native reader failed at frame $frame."
        }
        for ($i = 0; $i -lt $names.Count; ++$i) {
            $series = $native.signals[$i]
            if ($series.name -cne $names[$i] -or $series.changes.Count -ne 1 -or
                $series.changes[0][0] -ne $frame -or $series.changes[0][1] -cne $step.values[$i]) {
                throw "Wrong native value for $($names[$i]) at frame $frame."
            }
        }
    }

    $measurements = @(1..$Repeats | ForEach-Object {
        $pass = & node (Join-Path $PSScriptRoot 'measure_debug_navigation.cjs') $page $trace --workload $workloadPath |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'The renderer measurement failed.' }
        $expectedBytes = @(98816, 0, 98816, 98816, 98816, 98816, 0)
        $expectedRanges = @(64, 0, 64, 64, 64, 64, 0)
        for ($i = 0; $i -lt $expectedBytes.Count; ++$i) {
            if ($pass.viewports[$i].viewport_bytes -ne $expectedBytes[$i] -or
                $pass.viewports[$i].viewport_ranges -ne $expectedRanges[$i]) {
                throw "Unexpected number of file bytes or ranges at viewport step $i."
            }
        }
        $pass
    })
    [ordered]@{
        schema = 'Q3AFORMAL_DEBUG_VIEWPORT_CACHE_PILOT_1'
        os = [Environment]::OSVersion.VersionString
        architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        source_executable_sha256 = (Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
        renderer_source_sha256 = (Get-FileHash -LiteralPath (
            Join-Path $prototype 'source/bundle/debug_page_script.inc')).Hash.ToLowerInvariant()
        fixture_trace_sha256 = (Get-FileHash -LiteralPath $trace).Hash.ToLowerInvariant()
        fixture_html_sha256 = (Get-FileHash -LiteralPath $page).Hash.ToLowerInvariant()
        workload = $workload
        native_reader_cases_checked = $steps.Count * $names.Count
        measurements = $measurements
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFile -Encoding utf8
    "PASS: $Repeats renderer repeats, 16 signals, cold reads, zero-read overlap, and bounded eviction."
} finally {
    $generated = @($generator, $trace, $page, $workloadPath) | Where-Object { Test-Path -LiteralPath $_ }
    if ($generated) { Remove-Item -LiteralPath $generated -Force }
    Remove-Item -LiteralPath $root
}
