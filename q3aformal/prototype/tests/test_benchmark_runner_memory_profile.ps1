#requires -Version 7.0
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$benchmarkRoot = Join-Path $repoRoot 'prototype\benchmark'
$runnerPath = Join-Path $benchmarkRoot 'run_phase0_benchmarks.ps1'
$runId = [guid]::NewGuid().ToString('N')
$manifestPath = Join-Path $benchmarkRoot ('.memory-profile-test-' + $runId + '.json')
$outputRelative = 'evidence/benchmark/memory-profile-test-' + $runId
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $outputRelative))
$repoPrefix = $repoRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

if (-not $outputPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary benchmark test output resolved outside the repository.'
}
if ((Test-Path -LiteralPath $manifestPath) -or (Test-Path -LiteralPath $outputPath)) {
    throw 'Temporary benchmark test path unexpectedly already exists.'
}

$manifest = [ordered]@{
    schema = 'Q3AFORMAL_PHASE0_BENCHMARK_JOBS_1'
    host_profile_override = [ordered]@{
        installed_memory_label = '16 GB'
        source = 'User-reported, 2026-11-20'
    }
    jobs = @(
        [ordered]@{
            id = 'host-profile-smoke'
            executable = '../bin/q3aformal-sourcecheck.exe'
            working_directory = '../..'
            arguments = @('--lower-project', 'prototype/counter4.q3a')
            input_files = @(
                '../../prototype/counter4.q3a',
                '../../prototype/corpus/source-model-vectors/counter4_pass.sv'
            )
            expected_exit_code = 0
            timeout_seconds = 30
        }
    )
}

try {
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    & $runnerPath -JobsPath $manifestPath -OutputDirectory $outputRelative

    $environmentPath = Join-Path $outputPath 'environment.json'
    $measurementsPath = Join-Path $outputPath 'measurements.csv'
    if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $measurementsPath -PathType Leaf)) {
        throw 'Benchmark runner did not write the expected environment and measurement records.'
    }
    $environment = Get-Content -LiteralPath $environmentPath -Raw | ConvertFrom-Json
    $measurement = Import-Csv -LiteralPath $measurementsPath | Select-Object -First 1
    if ($measurement.measurement_verdict -ne 'EXPECTED') {
        throw "Smoke job did not match its expected outcome: $($measurement.measurement_verdict)"
    }

    if ($null -eq $environment.installed_memory_bytes) {
        if ($environment.installed_memory_source -ne 'User-reported, 2026-11-20' -or
            $environment.installed_memory_label -ne '16 GB' -or
            $environment.host_profile_status -ne 'CAPTURED_WITH_USER_OVERRIDE') {
            throw 'Unavailable installed RAM did not preserve the sourced 16 GB user override.'
        }
    } else {
        if ($environment.installed_memory_source -ne 'Windows API' -or
            $environment.installed_memory_label -ne "$($environment.installed_memory_bytes) bytes") {
            throw 'Installed RAM bytes were not sourced from the Windows installed-memory API.'
        }
    }

    Write-Output "PASS: installed RAM source '$($environment.installed_memory_source)' remains distinct from OS-visible physical memory; smoke measurement is EXPECTED."
} finally {
    if (Test-Path -LiteralPath $outputPath) {
        $resolvedOutputPath = [System.IO.Path]::GetFullPath($outputPath)
        if (-not $resolvedOutputPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove benchmark test output outside the repository.'
        }
        Remove-Item -LiteralPath $resolvedOutputPath -Recurse -Force
    }
    if (Test-Path -LiteralPath $manifestPath) {
        $resolvedManifestPath = [System.IO.Path]::GetFullPath($manifestPath)
        if (-not $resolvedManifestPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove benchmark test manifest outside the repository.'
        }
        Remove-Item -LiteralPath $resolvedManifestPath -Force
    }
}
