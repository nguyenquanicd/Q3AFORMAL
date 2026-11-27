#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$OutputFile,
    [Parameter(Mandatory)][string]$BaselinePage,
    [string]$PriorBackgroundPage,
    [string]$Compiler = 'g++',
    [ValidateRange(1, 20)][int]$Repeats = 3
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$baseline = (Resolve-Path -LiteralPath $BaselinePage).Path
$prior = if ($PriorBackgroundPage) { (Resolve-Path -LiteralPath $PriorBackgroundPage).Path }
$prototype = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $prototype 'bin/q3aformal-sourcecheck.exe'
$root = (New-Item -ItemType Directory -Path (
    Join-Path ([IO.Path]::GetTempPath()) ('q3a-change-search-' + [guid]::NewGuid().ToString('N')))).FullName
$generator = Join-Path $root 'fixture.exe'
$trace = Join-Path $root 'trace.q3atrace'
$page = Join-Path $root 'page.html'
$baselineFixturePage = Join-Path $root 'baseline.html'
$priorFixturePage = Join-Path $root 'previous-background.html'
$workloadPath = Join-Path $root 'workload.json'
$backgroundWorkloadPath = Join-Path $root 'background-workload.json'

try {
    & $Compiler -std=c++17 -O2 (Join-Path $PSScriptRoot 'large_trace_fixture.cpp') (
        Join-Path $prototype 'source/bundle/indexed_trace.cpp') (
        Join-Path $prototype 'source/bundle/debug_view.cpp') -o $generator
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the fixture generator.' }
    & $generator $root --sparse
    if ($LASTEXITCODE -ne 0) { throw 'Could not write the sparse trace.' }

    $pattern = [regex]::new('<script>\s*([\s\S]*?)</script>')
    $oldRenderer = $pattern.Match((Get-Content -LiteralPath $baseline -Raw))
    if (!$oldRenderer.Success -or $oldRenderer.Value -cmatch 'function indexChanges') {
        throw 'Expected the baseline HTML renderer without the change index.'
    }
    $currentPage = Get-Content -LiteralPath $page -Raw
    $pattern.Replace($currentPage, [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $oldRenderer.Value
    }, 1) | Set-Content -LiteralPath $baselineFixturePage -Encoding utf8

    if ($prior) {
        $priorRenderer = $pattern.Match((Get-Content -LiteralPath $prior -Raw))
        if (!$priorRenderer.Success -or $priorRenderer.Value -cnotmatch 'Stop indexing' -or
            $priorRenderer.Value -cmatch 'previousValues') {
            throw 'Expected an earlier renderer with background indexing and no boundary value reuse.'
        }
        $pattern.Replace($currentPage, [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $priorRenderer.Value
        }, 1) | Set-Content -LiteralPath $priorFixturePage -Encoding utf8
    }

    $lanes = @(0..15 | ForEach-Object { $_ * 25 })
    $signals = @($lanes | ForEach-Object { 'lane_{0:D3}' -f $_ })
    $native = & $exe trace window $trace --first 0 --last 10000 --signal lane_000 --signal lane_025 |
        ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $native.signals.Count -ne 2 -or
        (ConvertTo-Json -InputObject $native.signals[0].changes -Compress) -cne '[[0,"0x0"],[256,"0x400"],[9984,"0x800"]]' -or
        (ConvertTo-Json -InputObject $native.signals[1].changes -Compress) -cne '[[0,"0x19"],[256,"0x419"],[9983,"0x819"]]') {
        throw 'Native reader did not reproduce the expected sparse changes.'
    }
    $steps = @(
        @{frame=260},
        @{frame=9983; direction='next'},
        @{frame=256; direction='previous'},
        @{frame=9983; direction='next'},
        @{frame=9984; direction='next'},
        @{frame=9984; direction='next'; noChange=$true},
        @{frame=9983; direction='previous'},
        @{frame=256; direction='previous'}
    )
    foreach ($step in $steps) {
        $step.values = @($lanes | ForEach-Object {
            $level = if ($step.frame -ge 9984 -or ($_ -eq 25 -and $step.frame -eq 9983)) { 2 } else { 1 }
            '0x{0:x}' -f (1024 * $level + $_)
        })
    }
    $workload = [ordered]@{signals=$signals; span=32; steps=$steps}
    $workload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $workloadPath -Encoding utf8

    $backgroundSteps = @($steps[0], @{frame=260; background=$true; values=$steps[0].values}) + $steps[1..7]
    $backgroundWorkload = [ordered]@{signals=$signals; span=32; steps=$backgroundSteps}
    $backgroundWorkload | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $backgroundWorkloadPath -Encoding utf8

    $script = Join-Path $PSScriptRoot 'measure_debug_navigation.cjs'
    $results = @(1..$Repeats | ForEach-Object {
        $old = & node $script $baselineFixturePage $trace --workload $workloadPath | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Baseline renderer search failed.' }
        $new = & node $script $page $trace --workload $workloadPath | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Candidate renderer search failed.' }
        if ($new.viewports[1].viewport_ranges -ne $old.viewports[1].viewport_ranges -or
            $new.change_index_entries -ne 624 -or $new.change_index_payload_bytes -ne (624 * 32) -or
            $new.viewports[2].viewport_ranges -gt 64 -or $old.viewports[2].viewport_ranges -lt 1000 -or
            $new.viewports[3].viewport_ranges -ne 0 -or $old.viewports[3].viewport_ranges -lt 1000 -or
            @($new.viewports[4..7] | Where-Object viewport_ranges -NE 0).Count) {
            throw 'Unexpected cold or repeated waveform search read counts.'
        }
        $background = & node $script $page $trace --workload $backgroundWorkloadPath | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $background.change_index_entries -ne 640 -or
            $background.change_index_payload_bytes -ne (640 * 32) -or
            $background.viewports[1].viewport_ranges -ne 1216 -or
            $background.viewports[2].viewport_ranges -ne 64 -or
            @($background.viewports[3..8] | Where-Object viewport_ranges -NE 0).Count) {
            throw 'Background indexing failed to preserve the waveform cache and remove search reads.'
        }
        $result = [ordered]@{baseline=$old; candidate=$new; preindexed=$background}
        if ($prior) {
            $earlier = & node $script $priorFixturePage $trace --workload $backgroundWorkloadPath | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or $earlier.viewports[1].viewport_ranges -ne 2400) {
                throw 'Unexpected previous background indexing workload.'
            }
            $result.previous_background = $earlier
        }
        $result
    })
    [ordered]@{
        schema='Q3AFORMAL_DEBUG_SPARSE_CHANGE_SEARCH_3'
        source_executable_sha256=(Get-FileHash -LiteralPath $exe).Hash.ToLowerInvariant()
        baseline_page_sha256=(Get-FileHash -LiteralPath $baseline).Hash.ToLowerInvariant()
        previous_background_page_sha256=if ($prior) { (Get-FileHash -LiteralPath $prior).Hash.ToLowerInvariant() }
        fixture_trace_sha256=(Get-FileHash -LiteralPath $trace).Hash.ToLowerInvariant()
        candidate_page_sha256=(Get-FileHash -LiteralPath $page).Hash.ToLowerInvariant()
        workload=$workload
        background_workload=$backgroundWorkload
        native_reader=$native
        measurements=$results
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutputFile -Encoding utf8
    "PASS $Repeats repeats of sparse change search, background indexing, checkpoint edges and trace exhaustion."
} finally {
    $generated = @($generator, $trace, $page, $baselineFixturePage, $priorFixturePage, $workloadPath, $backgroundWorkloadPath) |
        Where-Object { Test-Path -LiteralPath $_ }
    if ($generated) { Remove-Item -LiteralPath $generated -Force }
    Remove-Item -LiteralPath $root
}
